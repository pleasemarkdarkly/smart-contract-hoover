pragma solidity ^0.4.18;

// ----------------------------------------------------------------------------
// &#39;ACLYDcid&#39; Corporate Identity Token
// Company Name         : The Aclyd Project LTD.
// Company Reg. Number  : No. 202470 B
// Jursidiction         : Nassau, Island of New Providence, Common Weatlh of Bahamas
// Type of Organization : International Business Company
// Reg. Agent Name      : KLA CORPORATE SERVICES LTD.
// Reg. Agent Address   : 48 Village Road (North) Nassau, New Providence,Bahamas
//                      : P.O Box N-3747, Nassau, Bahamas.
// CID Token Wallet     : 0x2bea96F65407cF8ed5CEEB804001837dBCDF8b23
// CID Token Symbol     : ACLYDcid
// Number of CID tokens : 11
// CID Listing Wallet   : 0x81cFa21CD58eB2363C1357c46DD9F553459F9B53
//
// ----------------------------------------------------------------------------
// ICO Token Details      
// ICO token Standard        : ERC20
// ICO token Contract Address: 0x34B4af7C75342f01c072FA780443575BE5E20df1
// ICO token Symbol          : ACLYD
// ICO token Supply          : 750,000,000
//
// (c) by The ACLYD Project  
// ----------------------------------------------------------------------------


// ----------------------------------------------------------------------------
// Safe maths
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
        require(b > 0);
        c = a / b;
    }
}


// ----------------------------------------------------------------------------
// ERC Token Standard #20 Interface
// https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
// ----------------------------------------------------------------------------
contract ERC20Interface {
    function cidTokenSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}


// ----------------------------------------------------------------------------
// Contract function to receive approval and execute function in one call
//
// Borrowed from ACLYD TOKEN
// ----------------------------------------------------------------------------
contract ApproveAndCallFallBack {
    function receiveApproval(address from, uint256 tokens, address token, bytes data) public;
}


// ----------------------------------------------------------------------------
// Owned contract
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
        OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }
}


// ----------------------------------------------------------------------------
// ERC20 Token, with the addition of symbol, name and decimals and assisted
// token transfers
// ----------------------------------------------------------------------------
contract ACLYDcidTOKEN is ERC20Interface, Owned, SafeMath {
    /* Public variables of the TheAclydProject */
    string public companyName = "The Aclyd Project LTD.";
    string public companyRegNum = "No. 202470 B";
    string public companyJurisdiction = "Nassau, Bahamas";
    string public organizationtype  = "International Business Company";
    string public regAgentName = "KLA CORPORATE SERVICES LTD.";
    string public regAddress = "48 Village Road (North) Nassau, New Providence, Bahamas, P.O Box N-3747";
    string public cidWalletAddress = "0x2bea96F65407cF8ed5CEEB804001837dBCDF8b23";
    string public cidTokenSymbol = "ACLYDcid";
    uint8 public  decimals;
    uint public   _cidTokenSupply; 
    string public icoTokenstandard = "ERC20";
    string public icoTokensymbol = "ACLYD";
    string public icoTokenContract = "0xAFeB1579290E60f72D7A642A87BeE5BFF633735A";
    string public cidListingWallet = "0x81cFa21CD58eB2363C1357c46DD9F553459F9B53";


    mapping(address => uint) balances;
    mapping(address => mapping(address => uint)) allowed;


    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    function ACLYDcidTOKEN() public {
        cidTokenSymbol = "ACLYDcid";
        companyName = "The Aclyd Project LTD.";
        decimals = 0;
        _cidTokenSupply = 11;
        balances[0x2bea96F65407cF8ed5CEEB804001837dBCDF8b23] = _cidTokenSupply;
        Transfer(address(0), 0x2bea96F65407cF8ed5CEEB804001837dBCDF8b23, _cidTokenSupply);
    }


    // ------------------------------------------------------------------------
    // Total supply
    // ------------------------------------------------------------------------
    function cidTokenSupply() public constant returns (uint) {
        return _cidTokenSupply  - balances[address(0)];
    }


    // ------------------------------------------------------------------------
    // Get the token balance for account tokenOwner
    // ------------------------------------------------------------------------
    function balanceOf(address tokenOwner) public constant returns (uint balance) {
        return balances[tokenOwner];
    }


    // ------------------------------------------------------------------------
    // Transfer the balance from token owner&#39;s account to  account
    // - Owner&#39;s account must have sufficient balance to transfer
    // - 0 value transfers are allowed
    // ------------------------------------------------------------------------
    function transfer(address to, uint tokens) public returns (bool success) {
        balances[msg.sender] = safeSub(balances[msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
        Transfer(msg.sender, to, tokens);
        return true;
    }


    // ------------------------------------------------------------------------
    // Token owner can approve for spender to transferFrom(...) tokens
    // from the token owner&#39;s account
    //
    // https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
    // recommends that there are no checks for the approval double-spend attack
    // as this should be implemented in user interfaces 
    // ------------------------------------------------------------------------
    function approve(address spender, uint tokens) public returns (bool success) {
        allowed[msg.sender][spender] = tokens;
        Approval(msg.sender, spender, tokens);
        return true;
    }


    // ------------------------------------------------------------------------
    // Transfer tokens from the from account to the to account
    // 
    // The calling account must already have sufficient tokens approve(...)-d
    // for spending from the from account and
    // - From account must have sufficient balance to transfer
    // - Spender must have sufficient allowance to transfer
    // - 0 value transfers are allowed
    // ------------------------------------------------------------------------
    function transferFrom(address from, address to, uint tokens) public returns (bool success) {
        balances[from] = safeSub(balances[from], tokens);
        allowed[from][msg.sender] = safeSub(allowed[from][msg.sender], tokens);
        balances[to] = safeAdd(balances[to], tokens);
        Transfer(from, to, tokens);
        return true;
    }


    // ------------------------------------------------------------------------
    // Returns the amount of tokens approved by the owner that can be
    // transferred to the spender&#39;s account
    // ------------------------------------------------------------------------
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining) {
        return allowed[tokenOwner][spender];
    }


    // ------------------------------------------------------------------------
    // Token owner can approve for spender to transferFrom(...) tokens
    // from the token owner&#39;s account. The spender contract function
    // receiveApproval(...) is then executed
    // ------------------------------------------------------------------------
    function approveAndCall(address spender, uint tokens, bytes data) public returns (bool success) {
        allowed[msg.sender][spender] = tokens;
        Approval(msg.sender, spender, tokens);
        ApproveAndCallFallBack(spender).receiveApproval(msg.sender, tokens, this, data);
        return true;
    }


    // ------------------------------------------------------------------------
    // Don&#39;t accept ETH
    // ------------------------------------------------------------------------
    function () public payable {
        revert();
    }


    // ------------------------------------------------------------------------
    // Owner can transfer out any accidentally sent ERC20 tokens
    // ------------------------------------------------------------------------
    function transferAnyERC20Token(address tokenAddress, uint tokens) public onlyOwner returns (bool success) {
        return ERC20Interface(tokenAddress).transfer(owner, tokens);
    }
}