/**
 *Submitted for verification at Etherscan.io on 2021-05-02
*/

pragma solidity >=0.6.0;

/*
                                                    ./>.
                                    .<.           ./>>>>>.            .-
                                    (>>>>><....<>>>>>>>>>>>>><...><>>>>>
                                   (>>>>>>>>===   ........   ====>>>>>>>>
                                 ./>>>== ..<>>>==============>>>>>. ==>>>>>
                              .<>>=  (>>==                        ==>>>. =\>><.
                      (>>>>>>>>= ./>=       ..<>>>>>>>>>>>>>>>>..      =\>< =\>>>>>>>>
                      (>>>>>= ./>=     .<>>>>>>>>>>>>>>>>>>>>>>>>>>>>.    =\>> =\>>>>=
                      (>>>= </=-    <>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>.    =\> =\>>>
                     ./>= (/=    (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>.   =\> =\>+
                    (/= (/=    (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>+   =\> (>>
                 .<>>= (=    (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>.   (> (\>>.
            (>>>>>>/ ./=   ./>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>   (\-.(>>>>>>+
             (\>>>>=./=   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=   =>>>>>>>>>>>.  =\> (>>>>=
              (>>>=./=   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=       \>>>>>>>>>>-  (\>.\>>=
               (>= (=   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>          \>>>>>>>>>>   (> (>>
               (>-(/   ./>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=            (>>>>>>>>>>   (> (>
              (>= (=   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=     .<>>     (>>>>>>>>>>  (> (>>
             (>>= /=   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=     (>====>>    (>>>>>>>>>   (> (>>.
          ./>>>>-(>   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=    .<========>.   (>>>>>>>>   (> (>>>>.
         =\>>>>>-(>   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=     />==========>>   =>>>>>>>   (= (>>>>>=
            =>>>-(>   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=    .>=====<<<<<<===>.   \>>>>>   (= (>>=
              (>) (>   (>>>>>>>>>>>>>>>>>>>>>>>>>>>>=    .>=====(<<<<<<<<</==>.  =\>>=  (/=(>>=
               (> (>   (>>>>>>>>>>>>>>>>>>>>>>>>>=.    .>====\(<<<<<<<<<<<<</==>.  ==-  (/ (>=
               (>=(\=   (>>>>>>>>>>>>>>>>>>>==      .<>====\/<<<<<<<<<<<<<<<<<</=>>.    /=(/>
               (>> (>   (>>>>>>>>>>>====        ./>>====\<<<<<<<<<<<<<<<<<<<<<<<<</=   (= (>>
              (>>>> (>                   ...<>>>====\<<<<<<<<<<<<<<<<<<<<<<<<<<<<</   (> (>>>\
             (>>>>>> (>    ..../<<<>==========\\<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<=   (= (>>>>>>
              ===>>>> (>.   ======<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<=  ./= (>>>===
                   =\>.=\>   =\<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<=   (/= (>=
                     (>> (\<   =\<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<=   ./= (//
                      (>>> (>>   =<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<=   ./= ./>>
                      (>>>>< =\>.    =<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<=   .</=../>>>=
                      (>>>>>>>. =>>.    ==<<<<<<<<<<<<<<<<<<<<<<<<==    .<>= .<>>>>>>>
                      (======>>>>. =\>>.      ====<<<<<<<<=====     .<>>= .(>>>=======
                                =\>>>. ==>>>>..              ...<>>== ..>>>=
                                  (>>>>>>>... =====>>>>>>======...<>>>>>>=
                                   (\>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>=
                                    (>==         =>>>>>>>>==       .==>=
                                                   =\>>>=
                                                     ==
                                                     
     
             ▄▄▄▄     ▄▄▄▄▄▄▄▄▄▄▄  ▄▄           ▄▄▄▄▄▄▄▄▄▄▄   ▄▄▄▄▄▄▄▄▄▄   ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄
             ████     ██▀▀▀▀▀▀▀██  ██           ███▀▀▀▀████  ▐██▀▀▀▀▀▀██▌  ██▀▀▀▀▀▀▀▀▀  ▀▀▀▀▀██▀▀▀▀
               ██     ███████████  ██           ███████████  ▐██      ██▌  ███████████       ██
               ██     ████         ██           ██▌    ████  ▐████    ██▌  ████              ████
               ██     ████         ███████████  ██▌    ████  ▐████    ██▌  ████              ████
           ████████▌  ████         ███████████  ███    ████  ▐████    ██▌  ███████████       ████
*/


// ---------------------------------------------------------------------------------------------------------------
// '1PLCO2' token contract
//  1PLCO2 is a tokenized Carbon Credit.
//  1PLCO2 = 1 Carbon Credit = 1 metric ton of CO2
//  This 1PLANET contract also offers direct offsetting functions for dApps and Smart Contracts such as NFT minting.
//  When 1PLCO2 is burned/retired then carbon credits are also permenantly burned/retired for carbon offsetting.
//  Use the dApp at www.1PLANET.app and see www.climatefutures.io for more information.
//------------------------------------------------------------------------------------------------------------------

//import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";
//import "./github/smartcontractkit/chainlink/evm-contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";

interface AggregatorV3Interface {

  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);

  // getRoundData and latestRoundData should both raise "No data present"
  // if they do not have data to report, instead of returning unset values
  // which could be misinterpreted as actual reported values.
  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}
    

abstract contract DAIpaymentInterface {
    
     function balanceOf(address _owner) public view virtual returns (uint256 balance);
     function approve(address usr, uint wad) external virtual returns (bool);
     function transferFrom(address spender, address dst, uint wad) public virtual returns (bool);
     function allowance(address tokenOwner, address spender) public virtual view returns (uint remaining);
}


// ----------------------------------------------------------------------------
// Safe math
// ----------------------------------------------------------------------------
contract SafeMath {
    function safeAdd(uint a, uint b) internal pure returns (uint c) {
        c = a + b;
        require(c >= a);
    }
    function safeSub(uint a, uint b) internal pure returns (uint c) {
        require(b <= a);
        c = a - b;
    }
    function safeMul(uint a, uint b) internal pure returns (uint c) {
        c = a * b;
        require(a == 0 || c / a == b);
    }
    function safeDiv(uint a, uint b) internal pure returns (uint c) {
        require(b > 0);
        c = a / b;
    }

}

// ----------------------------------------------------------------------------
// ERC Token Standard #20 Interface
// https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
// ----------------------------------------------------------------------------
abstract contract ERC20Interface {
    function totalSupply() public virtual view returns (uint);
    function balanceOf(address tokenOwner) public virtual view returns (uint balance);
    function allowance(address tokenOwner, address spender) public virtual view returns (uint remaining);
    function transfer(address to, uint tokens) public virtual returns (bool success);
    function approve(address spender, uint tokens) public virtual returns (bool success);
    function transferFrom(address from, address to, uint tokens) public virtual returns (bool success);
    
    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}


// ----------------------------------------------------------------------------
// Contract function to receive approval and execute function in one call
//
// Borrowed from MiniMeToken
// ----------------------------------------------------------------------------
abstract contract ApproveAndCallFallBack {
    function receiveApproval(address from, uint256 tokens, address token, bytes memory data) public virtual;
}


// ----------------------------------------------------------------------------
// Owned contract
// ----------------------------------------------------------------------------
contract Owned {
    address payable public owner;
    address payable public newOwner;

    event OwnershipTransferred(address indexed _from, address indexed _to);

    constructor() public {
        owner = 0xacCeB894DbA9632E49C56bC0ED75e515aeA95a12;
    }

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

    function transferOwnership(address payable _newOwner) public onlyOwner {
        newOwner = _newOwner;
    }
    function acceptOwnership() public {
        require(msg.sender == newOwner);
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }
}

abstract contract OnePlanetInterface {
    
     function balanceOf(address _owner) public view virtual returns (uint256 balance);
     function retireOnePL(uint tokens, string memory message) public virtual returns (bool success);
     function gasCO2factor() public view virtual returns (uint256);
     function ethPrice1PL() public view virtual returns (uint256);
     function offsetDirectWithETH(string calldata message) external virtual payable returns (bool success);
}

contract StringUtils {
        function integerToString(uint256 _i) internal pure returns (string memory) {
        
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len - 1;
        
        while (_i != 0) {
            bstr[k--] = byte(uint8(48 + _i % 10));
            _i /= 10;
        }
        return string(bstr);
    }

        function concat(string memory str1, string memory str2) internal pure returns (string memory result) {
            return(string(abi.encodePacked(str1, str2)));
        }
    }

abstract contract OnePlanetConnected is StringUtils, Owned{
    using SafeMath2 for uint256;
    //OnePlanet State Variables
    address public OnePlanetAddress;
	uint256 public gasCO2factor;
	uint256 public gasEstModifier;
    uint256 public gasAtStart;
    uint256 public gasEst;
    uint256 public CO2offset;
    
    uint256 public CO2offsetETH;
    uint256 public ethPrice1PL;
    
	string public offsetMsgBase;
	uint8 public checkGasFactor; // used to turn off or on the auto updating of the factor from 1PLANET contract
	uint8 public offsetSwitch; // used to turn off or on the function or choose the carbon offseting option;
    
    constructor() public {
        //OnePlanet Carbon Offset Settings
        OnePlanetAddress = 0xFf266BD7b425576D4569B1C0d9d7ef35C4C07567;
        gasCO2factor = 380000000000;
        checkGasFactor = 1;
        offsetSwitch = 1;
        offsetMsgBase = "These tokens are minted climate friendly using 1PLANET! Visit www.1PLANET.app to verify the Tx info. Burning one 1PLCO2 offsets 1 metric ton of CO2. Gas Offset=";
        gasEstModifier = 100000;
    }
    
    modifier OnePlanetCarbonOffset {
        
        OnePlanetInterface OnePlanetInstance = OnePlanetInterface(OnePlanetAddress);
        
        if(offsetSwitch == 1 && OnePlanetInstance.balanceOf(address(this)) >= 1e18){
        
            gasAtStart = gasleft();
            _;
            gasEst = gasAtStart.sub(gasleft());
        
            offsetWith1PL(gasEst);
        
        } else {
            _;
        }
    
    }


    function offsetWith1PL(uint256 gasEstOffset) internal {
        OnePlanetInterface OnePlanetInstance = OnePlanetInterface(OnePlanetAddress);
        gasCO2factor = checkGasFactor == 1 ? OnePlanetInstance.gasCO2factor(): 0;
        gasEstOffset = gasEstModifier != 0 ? gasEstOffset.add(gasEstModifier): 0;
        CO2offset = gasEstOffset.mul(gasCO2factor); //gas used multiplied by C02 coversion factor

        string memory gasEstOffsetStr = integerToString(gasEstOffset);
        string memory offsetMsgBaseCopy = offsetMsgBase;
        string memory offsetMsgFull = concat(offsetMsgBaseCopy, gasEstOffsetStr);

        require(OnePlanetInstance.balanceOf(address(this)) >= CO2offset, "Not enough 1PLCO2 tokens to retire"); //Require that the NFT minter has enough 1PLANET tokens
        
        OnePlanetInstance.retireOnePL(CO2offset, offsetMsgFull); //Retire 1Planet tokens based on CO2 emitted
        }
     

     function offsetWithETH(uint256 gasEstOffset) internal {
        OnePlanetInterface OnePlanetInstance = OnePlanetInterface(OnePlanetAddress);
        gasCO2factor = checkGasFactor == 1 ? OnePlanetInstance.gasCO2factor() : 0;
        ethPrice1PL = OnePlanetInstance.ethPrice1PL();
        gasEstOffset = gasEstModifier != 0 ? gasEstOffset.add(gasEstModifier): 0;
        CO2offset = gasEstOffset.mul(gasCO2factor); //gas used multiplied by C02 coversion factor
        CO2offsetETH = (CO2offset.mul(ethPrice1PL)).div(1e18);

        string memory gasEstOffsetStr = integerToString(gasEstOffset);
        string memory offsetMsgBaseCopy = offsetMsgBase;
        string memory offsetMsgFull = concat(offsetMsgBaseCopy, gasEstOffsetStr);

        require(address(this).balance >= CO2offsetETH, "Not enough ETH for transaction"); //Require that the NFT minter has enough ETH
        OnePlanetInstance.offsetDirectWithETH.value(CO2offsetETH)(offsetMsgFull); //Retire 1Planet tokens based on CO2 emitted in ETH
        }
    
    
    //OnePlanet Owner Functions
    function setOffsetSwitch(uint8 offsetSwitchState) external onlyOwner {
        offsetSwitch = offsetSwitchState;
    }
    
    function setGasCO2factorUpdateSwitch(uint8 autoUpdateSwitchState) external onlyOwner {
        checkGasFactor = autoUpdateSwitchState;
    }
    
    function setGasEstModifier(uint256 safetyFactor) external onlyOwner {
        gasEstModifier = safetyFactor;
    }
    
    function updateOffsetMsgBase(string calldata message) external onlyOwner {
        offsetMsgBase = message;
    }
    
    function UpdateGasCO2factor (uint256 CO2factor) external onlyOwner {
        gasCO2factor = CO2factor;
    }
    
    function getLastestGasCO2factor () external onlyOwner {
        OnePlanetInterface OnePlanetInstance = OnePlanetInterface(OnePlanetAddress);
        gasCO2factor = OnePlanetInstance.gasCO2factor();
    }
    
    function update1PLANETaddress(address payable new1PLANETaddress) external onlyOwner {
        OnePlanetAddress = new1PLANETaddress;
	}

}

// ----------------------------------------------------------------------------
// ERC20 Token, with the addition of symbol, name and decimals and assisted
// token transfers
// ----------------------------------------------------------------------------
contract OnePlanetOffset is ERC20Interface, Owned, SafeMath, OnePlanetConnected {
    string public symbol;
    string public  name;
    uint8 public decimals;
    uint public _totalSupply;
    uint public startDate;
    uint public endDate;
    uint public _maxSupply;
    uint public updateInterval;
    uint public currentIntervalRound;
    AggregatorV3Interface internal priceFeed;
    uint public ethPrice;
    uint public ethAmount;
    uint public SigDigits;
    uint public offsetSigDigits;
    uint public tokenPrice;
	address payable public oracleAddress;
	address payable public daiAddress;
	address public retireAddress;
	
		// Matic Variables
	address payable internal MintableERC20PredicateProxy;
    address deployer;
    bytes32 public constant PREDICATE_ROLE = keccak256("0x12ff340d0cd9c652c747ca35727e68c547d0f0bfa7758d2e77f75acef481b4f2");

    event CarbonOffset(string message);
    event ApprovedDaiPurchase(address buyer, uint256 ApprovedAmount, bool success, bytes data);
    event Deposit(address indexed sender, uint value);
    mapping(address => uint) balances;
    mapping(address => mapping(address => uint)) allowed;

    
    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    constructor() public {
        symbol = "1PLCO2";
        name = "1PLANET Carbon Credit";
        decimals = 18;
        SigDigits = 100;
        offsetSigDigits = 1e15;
        tokenPrice = 1000;
        updateInterval = 1;
        endDate = now + 2000 weeks;
        _maxSupply = 150000000000000000000000000; // 150M tokens maximum supply = 150M metric tons CO2e
		oracleAddress = 0x9326BFA02ADD2366b30bacB125260Af641031331;
		retireAddress = 0x0000000000000000000000000000000000000000;
		gasCO2factor = 380000000000;  // 0.38 gCO2 per unit of gas
		daiAddress = 0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa; // Kovan address only
		priceFeed = AggregatorV3Interface(oracleAddress);
		
        //priceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); mainNet

        
        //Matic Constructor Arguments
        MintableERC20PredicateProxy = 0x37c3bfC05d5ebF9EBb3FF80ce0bd0133Bf221BC8;
        
}

    modifier onlyPredicate {
        require(msg.sender == MintableERC20PredicateProxy);
        _;
    }
    
    // ------------------------------------------------------------------------
    // Total supply
    // ------------------------------------------------------------------------
    function totalSupply() public override view returns (uint) {
        return _totalSupply  - balances[address(0)];
    }
	
    function maxSupply() public view returns (uint) {
        return _maxSupply;
    }

    // ------------------------------------------------------------------------
    // Get the token balance for account `tokenOwner`
    // ------------------------------------------------------------------------
    function balanceOf(address tokenOwner) public override view returns (uint balance) {
        return balances[tokenOwner];
    }

    // ------------------------------------------------------------------------
    // Transfer the balance from token owner's account to `to` account
    // - Owner's account must have sufficient balance to transfer
    // - 0 value transfers are allowed
    // ------------------------------------------------------------------------
    function transfer(address to, uint tokens) public OnePlanetCarbonOffset override returns (bool success) {
        balances[msg.sender] = safeSub(balances[msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
        emit Transfer(msg.sender, to, tokens);
        return true;
    }

    // ------------------------------------------------------------------------
    // Token owner can approve for `spender` to transferFrom(...) `tokens`
    // from the token owner's account
    //
    // https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
    // recommends that there are no checks for the approval double-spend attack
    // as this should be implemented in user interfaces
    // ------------------------------------------------------------------------
    function approve(address spender, uint tokens) public override returns (bool success) {
        allowed[msg.sender][spender] = tokens;
        emit Approval(msg.sender, spender, tokens);
        return true;
    }

    // ------------------------------------------------------------------------
    // Transfer `tokens` from the `from` account to the `to` account
    //
    // The calling account must already have sufficient tokens approve(...)-d
    // for spending from the `from` account and
    // - From account must have sufficient balance to transfer
    // - Spender must have sufficient allowance to transfer
    // - 0 value transfers are allowed
    // ------------------------------------------------------------------------
    function transferFrom(address from, address to, uint tokens) public override returns (bool success) {
        balances[from] = safeSub(balances[from], tokens);
        allowed[from][msg.sender] = safeSub(allowed[from][msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
        emit Transfer(from, to, tokens);
        return true;
    }


    // ------------------------------------------------------------------------
    // Returns the amount of tokens approved by the owner that can be
    // transferred to the spender's account
    // ------------------------------------------------------------------------
    function allowance(address tokenOwner, address spender) public override view returns (uint remaining) {
        return allowed[tokenOwner][spender];
    }


    // ------------------------------------------------------------------------
    // Token owner can approve for `spender` to transferFrom(...) `tokens`
    // from the token owner's account. The `spender` contract function
    // `receiveApproval(...)` is then executed
    // ------------------------------------------------------------------------
    function approveAndCall(address spender, uint tokens, bytes memory data) public returns (bool success) {
        allowed[msg.sender][spender] = tokens;
        emit Approval(msg.sender, spender, tokens);
        ApproveAndCallFallBack(spender).receiveApproval(msg.sender, tokens, address(this), data);
        return true;
    }

    // ------------------------------------------------------------------------
    // Send ETH to get 1PLCO2 tokens
    // ------------------------------------------------------------------------
    receive() external payable OnePlanetCarbonOffset {
        require(now >= startDate && now <= endDate);
        uint256 weiAmount = msg.value;
        uint256 tokens = _getTokenAmount(weiAmount);
        balances[msg.sender] = safeAdd(balances[msg.sender], tokens);
        _totalSupply = safeAdd(_totalSupply, tokens);
        emit Transfer(address(0), msg.sender, tokens);
        owner.transfer(msg.value);
        currentIntervalRound = safeAdd(currentIntervalRound, 1);
        if(currentIntervalRound == updateInterval) {
            getLatestPrice();
            currentIntervalRound = 0;
        }
    
    }

    function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
        uint256 temp = safeMul(weiAmount, ethPrice);
        temp = safeDiv(temp, SigDigits);
        temp = safeDiv(temp, tokenPrice);
        temp = safeMul(temp, 100);
        return temp;
    }
    
    function buy1PLwithDai(uint256 daiAmount) public OnePlanetCarbonOffset returns (bool success) {
        
        DAIpaymentInterface DAIpaymentInstance = DAIpaymentInterface(daiAddress);
        
        require(daiAmount > 0, "You need to send at least some DAI");
        require(DAIpaymentInstance.balanceOf(address(msg.sender)) >= daiAmount, "Not enough DAI");
        uint256 daiAllowance = DAIpaymentInstance.allowance(msg.sender, address(this));
        require(daiAllowance >= daiAmount, "You need to approve more DAI to be spent");
        
        uint256 tokens = safeDiv(daiAmount, tokenPrice);
        tokens = safeMul(tokens, 100);
        
        DAIpaymentInstance.transferFrom(msg.sender, address(this), daiAmount);
        
        balances[msg.sender] = safeAdd(balances[msg.sender], tokens);
        _totalSupply = safeAdd(_totalSupply, tokens);
        
        emit Transfer(address(0), msg.sender, tokens);
        return true;
    }
    
    
    function offsetDirectWithETH(string calldata message) external payable returns (bool success) {
        
        require(msg.value > 0, "You need to send at least some ETH");
        ethAmount = safeMul(msg.value, safeDiv(1e18, offsetSigDigits));
        uint tokens = safeDiv(ethAmount, ethPrice1PL);
        
        // tokens = safeDiv(tokens, offsetSigDigits);
        tokens = safeMul(tokens, offsetSigDigits); // only retire in kg
        balances[retireAddress] = safeAdd(balances[retireAddress], tokens);
        emit Transfer(address(0), retireAddress, tokens);
        emit CarbonOffset(message);
        _totalSupply = safeAdd(_totalSupply, tokens);
        getLatestPrice();
        return true;
    }
        
    //-----------------------------------------------------
    // Returns the latest Chainlink Oracle ETH USD price
    //-----------------------------------------------------
    function getLatestPrice() public {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        ethPrice = safeDiv(uint(price), 1000000);
        uint256 temp = safeMul(tokenPrice, 1e18);
        ethPrice1PL = safeDiv(temp, ethPrice);
    }

    function updateEthPriceManually(uint price) external onlyOwner {
        ethPrice = price;
    }
    
    function update1PLethPriceManually(uint price) external onlyOwner {
        ethPrice1PL = price;
    }
    
    
    //--------------------------------------------------------------------------------------
    // Added due to Matic <-> Ethereum PoS transfer requiring 1PLCO2 on Matic network to be
    // burned or minted. Eth supply can be increased if it is ever necessary.
    //--------------------------------------------------------------------------------------
    function setMaxVolume(uint maxVolume) external onlyOwner {
        _maxSupply = maxVolume;
    }
    
    //--------------------------------------------------------------------------------------
    // Oracle returns price in decimal cents to 2 decimal places. If this changes it can
    // be adjusted by changing this significant digit value.
    // Should be a power of 10.
    //--------------------------------------------------------------------------------------
    function setEthSigDigits(uint digits) external onlyOwner {
        SigDigits = digits;
    }
    
    function setOffsetSigDigits(uint digits) external onlyOwner {
        offsetSigDigits = digits;
    }


    function topUpBalance() public payable {
    }

    function withdrawFromBalance() public onlyOwner {
        owner.transfer(address(this).balance);
    }
    
    //-------------------------------------------------------------------------------------------
    // Enables dApps to generate custom messages for carbon offsetting applications with 1PLCO2
    // Can be used by third-party developers
    //-------------------------------------------------------------------------------------------
    function retireOnePL(uint tokens, string calldata message) external returns (bool success) {
        tokens = safeDiv(tokens, offsetSigDigits);
        tokens = safeMul(tokens, offsetSigDigits); // only retire in kg
        transfer(retireAddress, tokens);
        emit CarbonOffset(message);
        return true;
    }
    
    // ------------------------------------------------------------------------
    // Owner can transfer out any accidentally sent ERC20 tokens
    // ------------------------------------------------------------------------
    function transferAnyERC20Token(address tokenAddress, uint tokens) external onlyOwner returns (bool success) {
        return ERC20Interface(tokenAddress).transfer(owner, tokens);
    }
    
    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements
     *
     * - `to` cannot be the zero address.
     */

    function _mint(address to, uint256 tokens) internal virtual {
        require(to != address(0), "ERC20: mint to the zero address");
        require(now >= startDate && now <= endDate);
        require(_maxSupply >= safeAdd(_totalSupply, tokens));
        _beforeTokenTransfer(address(0), to, tokens);
        balances[to] = safeAdd(balances[to], tokens);
        _totalSupply = safeAdd(_totalSupply, tokens);
        emit Transfer(address(0), to, tokens);
    }
        /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
        function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
        
    // Matic Mint Function
        function mint(address user, uint256 amount) external  OnePlanetCarbonOffset onlyPredicate {
        _mint(user, amount);
    }
    
}


pragma solidity ^0.6.0;

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
library SafeMath2 {
  /**
    * @dev Returns the addition of two unsigned integers, reverting on
    * overflow.
    *
    * Counterpart to Solidity's `+` operator.
    *
    * Requirements:
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
    * - Subtraction cannot overflow.
    */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b <= a, "SafeMath: subtraction overflow");
    uint256 c = a - b;

    return c;
  }

  /**
    * @dev Returns the multiplication of two unsigned integers, reverting on
    * overflow.
    *
    * Counterpart to Solidity's `*` operator.
    *
    * Requirements:
    * - Multiplication cannot overflow.
    */
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
    // benefit is lost if 'b' is also tested.
    // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
    if (a == 0) {
      return 0;
    }

    uint256 c = a * b;
    require(c / a == b, "SafeMath: multiplication overflow");

    return c;
  }

  /**
    * @dev Returns the integer division of two unsigned integers. Reverts on
    * division by zero. The result is rounded towards zero.
    *
    * Counterpart to Solidity's `/` operator. Note: this function uses a
    * `revert` opcode (which leaves remaining gas untouched) while Solidity
    * uses an invalid opcode to revert (consuming all remaining gas).
    *
    * Requirements:
    * - The divisor cannot be zero.
    */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    // Solidity only automatically asserts when dividing by 0
    require(b > 0, "SafeMath: division by zero");
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold

    return c;
  }

  /**
    * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
    * Reverts when dividing by zero.
    *
    * Counterpart to Solidity's `%` operator. This function uses a `revert`
    * opcode (which leaves remaining gas untouched) while Solidity uses an
    * invalid opcode to revert (consuming all remaining gas).
    *
    * Requirements:
    * - The divisor cannot be zero.
    */
  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b != 0, "SafeMath: modulo by zero");
    return a % b;
  }
}