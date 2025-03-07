pragma solidity ^0.4.18;

// ----------------------------------------------------------------------------
// --- &#39;TSRX&#39; &#39;tessr.credit&#39; token contract
// --- Symbol      : TSRX
// --- Name        : tessr.credit
// --- Total supply: Generated from contributions
// --- Decimals    : 18
// --- @author EJS32 
// --- @title for 01101101 01111001 01101100 01101111 01110110 01100101
// --- (c) tessr.credit / tessr.io 2018. The MIT License.
// --- pragma solidity v0.4.21+commit.dfe3193c
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// --- Safe maths
// ----------------------------------------------------------------------------
contract SafeMath {
    function safeAdd(uint a, uint b) public pure returns (uint c) {
        c = a + b;
        require(c >= a);
    }
    function safeSub(uint a, uint b) public pure returns (uint c) {
        require(b <= a);
        c = a - b;
    }
    function safeMul(uint a, uint b) public pure returns (uint c) {
        c = a * b;
        require(a == 0 || c / a == b);
    }
    function safeDiv(uint a, uint b) public pure returns (uint c) {
        c = a / b;
        require(b > 0);
    }
}

// ----------------------------------------------------------------------------
// --- ERC Token Standard #20 Interface
// --- https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
// ----------------------------------------------------------------------------
contract ERC20Interface {
    function totalSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);
    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

// ----------------------------------------------------------------------------
// --- Contract function to receive approval and execute function in one call
// ----------------------------------------------------------------------------
contract ApproveAndCallFallBack {
    function receiveApproval(address from, uint256 tokens, address token, bytes data) public;
}

// ----------------------------------------------------------------------------
// --- Owned contract
// ----------------------------------------------------------------------------
contract Owned {
    address public owner;
    address public newOwner;
    event OwnershipTransferred(address indexed _from, address indexed _to);
    function Owned() public {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
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
}

// ----------------------------------------------------------------------------
// --- ERC20 Token, with the addition of symbol, name and decimals
// --- Receives ETH and generates tokens
// ----------------------------------------------------------------------------
contract tessrX is ERC20Interface, Owned, SafeMath {
    string public symbol;
    string public  name;
    uint8 public decimals;
    uint public _totalSupply;
    uint public startDate;
    uint public bonusEnds;
    uint public endDate;
    mapping(address => uint) balances;
    mapping(address => mapping(address => uint)) allowed;

// ------------------------------------------------------------------------
// --- Constructor
// ------------------------------------------------------------------------
    function tessrX() public {
        symbol = "TSRX";
        name = "tessr.credit";
        decimals = 18;
        _totalSupply = 600000000000000000000000000;
        startDate = now;
        bonusEnds = now + 7 days;
        endDate = now + 38 days;
        balances[owner] = _totalSupply;
         emit Transfer(address(0), owner, _totalSupply);
    }

// ------------------------------------------------------------------------
// --- Total supply
// ------------------------------------------------------------------------
    function totalSupply() public constant returns (uint) {
        return _totalSupply  - balances[address(0)];
    }

// ------------------------------------------------------------------------
// --- Get the token balance for account `tokenOwner`
// ------------------------------------------------------------------------
    function balanceOf(address tokenOwner) public constant returns (uint balance) {
        return balances[tokenOwner];
    }

// ------------------------------------------------------------------------
// --- Transfer the balance from token owner&#39;s account to the `to` account
// --- Owner&#39;s account must have sufficient balance to transfer
// --- 0 value transfers are allowed
// ------------------------------------------------------------------------
    function transfer(address to, uint tokens) public returns (bool success) {
        balances[msg.sender] = safeSub(balances[msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
         emit Transfer(msg.sender, to, tokens);
        return true;
    }

// ------------------------------------------------------------------------
// --- Token owner can approve for `spender` to transferFrom `tokens`
// ------------------------------------------------------------------------
    function approve(address spender, uint tokens) public returns (bool success) {
        allowed[msg.sender][spender] = tokens;
         emit Approval(msg.sender, spender, tokens);
        return true;
    }

// ------------------------------------------------------------------------
// --- Transfer `tokens` from the `from` account to the `to` account
// --- The calling account must already have sufficient tokens approved
// --- From account must have sufficient balance to transfer
// --- Spender must have sufficient allowance to transfer
// --- 0 value transfers are allowed
// ------------------------------------------------------------------------
    function transferFrom(address from, address to, uint tokens) public returns (bool success) {
        balances[from] = safeSub(balances[from], tokens);
        allowed[from][msg.sender] = safeSub(allowed[from][msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
         emit Transfer(from, to, tokens);
        return true;
    }

// ------------------------------------------------------------------------
// --- Returns the amount of tokens approved by the owner that can be transferred
// ------------------------------------------------------------------------
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining) {
        return allowed[tokenOwner][spender];
    }


// ------------------------------------------------------------------------
// --- Token owner can approve for `spender` to transferFrom `tokens`
// ------------------------------------------------------------------------
    function approveAndCall(address spender, uint tokens, bytes data) public returns (bool success) {
        allowed[msg.sender][spender] = tokens;
         emit Approval(msg.sender, spender, tokens);
        ApproveAndCallFallBack(spender).receiveApproval(msg.sender, tokens, this, data);
        return true;
    }

// ------------------------------------------------------------------------
// --- 5,000 tokens per 1 ETH, with 25% bonus
// ------------------------------------------------------------------------
    function () public payable {
        require(now >= startDate && now <= endDate);
        uint tokens;
        if (now <= bonusEnds) {
            tokens = msg.value * 6250;
        } else {
            tokens = msg.value * 5000;
        }
        balances[msg.sender] = safeAdd(balances[msg.sender], tokens);
        _totalSupply = safeAdd(_totalSupply, tokens);
         emit Transfer(address(0), msg.sender, tokens);
        owner.transfer(msg.value);
    }

// ------------------------------------------------------------------------
// --- Owner can transfer out any accidentally sent ERC20 tokens
// ------------------------------------------------------------------------
    function transferAnyERC20Token(address tokenAddress, uint tokens) public onlyOwner returns (bool success) {
        return ERC20Interface(tokenAddress).transfer(owner, tokens);
    }
}