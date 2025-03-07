pragma solidity ^0.4.25;

// ----------------------------------------------------------------------------
// BokkyPooBah&#39;s Pricefeed from a single source
//
// Deployed to: 0x4604646C55410EAa6Cf43b04d26071E36bC227Ef
//
// Enjoy. (c) BokkyPooBah / Bok Consulting Pty Ltd 2018. The MIT Licence.
// ----------------------------------------------------------------------------



// ----------------------------------------------------------------------------
// Owned contract
// ----------------------------------------------------------------------------
contract Owned {
    address public owner;
    address public newOwner;
    bool private initialised;

    event OwnershipTransferred(address indexed _from, address indexed _to);

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

    function initOwned(address _owner) internal {
        require(!initialised);
        owner = _owner;
        initialised = true;
    }
    function transferOwnership(address _newOwner) public onlyOwner {
        newOwner = _newOwner;
    }
    function acceptOwnership() public {
        require(msg.sender == newOwner);
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }
    function transferOwnershipImmediately(address _newOwner) public onlyOwner {
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }
}


// ----------------------------------------------------------------------------
// Maintain a list of operators that are permissioned to execute certain
// functions
// ----------------------------------------------------------------------------
contract Operated is Owned {
    mapping(address => bool) public operators;

    event OperatorAdded(address _operator);
    event OperatorRemoved(address _operator);

    modifier onlyOperator() {
        require(operators[msg.sender] || owner == msg.sender);
        _;
    }

    function initOperated(address _owner) internal {
        initOwned(_owner);
    }
    function addOperator(address _operator) public onlyOwner {
        require(!operators[_operator]);
        operators[_operator] = true;
        emit OperatorAdded(_operator);
    }
    function removeOperator(address _operator) public onlyOwner {
        require(operators[_operator]);
        delete operators[_operator];
        emit OperatorRemoved(_operator);
    }
}

// ----------------------------------------------------------------------------
// PriceFeed Interface - _live is true if the rate is valid, false if invalid
// ----------------------------------------------------------------------------
contract PriceFeedInterface {
    function getRate() public view returns (uint _rate, bool _live);
}


// ----------------------------------------------------------------------------
// Pricefeed from a single source
// ----------------------------------------------------------------------------
contract PriceFeed is PriceFeedInterface, Operated {
    string public name;
    uint public rate;
    bool public live;

    event SetRate(uint oldRate, bool oldLive, uint newRate, bool newLive);

    constructor(string _name, uint _rate, bool _live) public {
        initOperated(msg.sender);
        name = _name;
        rate = _rate;
        live = _live;
        emit SetRate(0, false, rate, live);
    }
    function setRate(uint _rate, bool _live) public onlyOperator {
        emit SetRate(rate, live, _rate, _live);
        rate = _rate;
        live = _live;
    }
    function getRate() public view returns (uint _rate, bool _live) {
        return (rate, live);
    }
}