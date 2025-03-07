pragma solidity >=0.4.22 <0.9.0;
library SafeMath {

  /**
  * @dev Multiplies two numbers, throws on overflow.
  */
  function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
    if (a == 0) {
      return 0;
    }
    c = a * b;
    assert(c / a == b);
    return c;
  }

  /**
  * @dev Integer division of two numbers, truncating the quotient.
  */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    // assert(b > 0); // Solidity automatically throws when dividing by 0
    // uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold
    return a / b;
  }

  /**
  * @dev Subtracts two numbers, throws on overflow (i.e. if subtrahend is greater than minuend).
  */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    assert(b <= a);
    return a - b;
  }

  /**
  * @dev Adds two numbers, throws on overflow.
  */
  function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
    c = a + b;
    assert(c >= a);
    return c;
  }
}
contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () public{
        address msgSender = msg.sender;
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}


contract ERC721{
     // Token name
    string private _name;

    // Token symbol
    string private _symbol;

    // Mapping from token ID to owner address
    mapping (uint256 => address) public _owners;

    // Mapping owner address to token count
    mapping (address => uint256) public _balances;

    // Mapping from token ID to approved address
    mapping (uint256 => address) public _tokenApprovals;

    // Mapping from token ID is exists
    //mapping (uint256 => bool) private _exists;

    

    // Mapping from owner to operator approvals
    mapping (address => mapping (address => bool)) private _operatorApprovals;
    constructor (string memory name_, string memory symbol_) public {

        _name = name_;
        _symbol = symbol_;
    }
    function balanceOf(address owner) public view  returns (uint256) {
        require(owner != address(0), "ERC721: balance query for the zero address");
        return _balances[owner];
    }
     function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: owner query for nonexistent token");
        return owner;
    }
    function name() public view  returns (string memory) {
        return _name;
    }
      function symbol() public view returns (string memory) {
        return _symbol;
    }
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        require(_exists(tokenId), "ERC721: approved query for nonexistent token");

        return _tokenApprovals[tokenId];
    }

    // function _isApprovedOrOwner(address sender,uint256 tokenId) public view returns (bool) {
    //     require(_exists[tokenId], "ERC721: approved query for nonexistent token");
    //     require(_exists[tokenId], "ERC721: approved query for nonexistent token");
    //     return _tokenApprovals[tokenId];
    // }
    

    function _approve(address to, uint256 tokenId) internal  {
        _tokenApprovals[tokenId] = to;
        //emit Approval(ERC721.ownerOf(tokenId), to, tokenId);
    }
     function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "ERC721: mint to the zero address");
        require(!_exists(tokenId), "ERC721: token already minted");

        //_beforeTokenTransfer(address(0), to, tokenId);

        _balances[to] += 1;
        _owners[tokenId] = to;

       // emit Transfer(address(0), to, tokenId);
    }
}

contract Sale is ERC721, Ownable{
    using SafeMath for uint256;
    struct Order{
        uint256 tokenId;
        uint256 price;
    }
    mapping (address => mapping (uint256 => Order)) public order_place;
    mapping (address => mapping (address => bool)) private _operatorApprovals;
    mapping (uint256 => address) public _creator;
    mapping (uint256 => uint256) public _royal;
    mapping (uint256 => address) public _tokenOwner;
    
    function orderPlace(address to, uint256 tokenId, uint256 _price) public{
        require( to == _owners[tokenId], "Is Not a Owner");
        Order memory order;
        order.tokenId = tokenId;
        order.price = _price;
        order_place[to][tokenId] = order;
    }
    function cancelOrder(uint256 tokenId) public{
        require( msg.sender == _owners[tokenId], "Is Not a Owner");
        delete order_place[msg.sender][tokenId];
    }
    function changePrice(uint256 value, uint256 tokenId) public{
        require( msg.sender == _owners[tokenId], "Is Not a Owner");
        require( value < order_place[msg.sender][tokenId].price);
        order_place[msg.sender][tokenId].price = value;
    }
    function saleToken(address payable admin,uint256 tokenId) public payable{
        require(msg.value > order_place[_tokenOwner[tokenId]][tokenId].price , "Insufficent found");
        require(_operatorApprovals[_owners[tokenId]][admin], "Token Not approved");
        require(_tokenApprovals[tokenId] == admin, "Token Not approved");
        //address payable create = payable(_creator[tokenId]);
        address payable create = address(uint160(address(_creator[tokenId])));
        //address payable owner = payable(_owners[tokenId]);
        address payable owner = address(uint160(address(_owners[tokenId])));
        uint256 value = msg.value;
        uint256 fee = value.mul(5).div(100);
        //service fees
        admin.transfer(fee);
        value = value - fee;
        uint256 roy = value.mul(_royal[tokenId]).div(100);
        //royalty
        create.transfer(roy);
        //owner
        value = value - roy;
        owner.transfer(value);
        _transfer(admin, msg.sender, tokenId);
        
    }
    function setApprovalForAll(address to, bool approved, uint256 tokenId) public {
       
        require(to != msg.sender, "ERC721: approve to caller");
        _approve(to, tokenId);
        _operatorApprovals[msg.sender][to] = approved;
    }
    function _transfer(address from, address to, uint256 tokenId) internal{
        require(to != address(0), "ERC721: transfer to the zero address");

        // Clear approvals from the previous owner
        _operatorApprovals[from][to] = false;
        delete order_place[from][tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        //emit Transfer(from, to, tokenId);
    }

    
}

contract NFTMint is ERC721,Sale{
     mapping(string => bool) _nameexits;
     uint256 public tokenid=0;
     mapping (uint256 => string) private _tokenURIs;
     
     
    
    constructor(
        string memory name,
        string memory symbol
    ) ERC721(name, symbol) public{
      
    }
    
    function mint(string memory _name, string memory tokenuri) public {
        require(!_nameexits[_name]);
        tokenid++;
        _mint(msg.sender, tokenid);
        _creator[tokenid]=msg.sender;
        _tokenOwner[tokenid]=msg.sender;
        _nameexits[_name] = true;
        _setTokenURI(tokenid, tokenuri);
    }
    function mintwithsale(string memory _name, string memory tokenuri, uint256 value, uint256 tokenId, uint256 royal) public {
        require(!_nameexits[_name]);
        _mint(msg.sender, tokenId);
        _creator[tokenId]=msg.sender;
        _tokenOwner[tokenId]=msg.sender;
        _royal[tokenId]=royal;
        _nameexits[_name] = true;
        _setTokenURI(tokenId, tokenuri);
        orderPlace(msg.sender, tokenId, value);
    }
  
    function _setTokenURI(uint256 tokenId, string memory _tokenURI) internal{
        require(_exists(tokenId), "ERC721Metadata: URI set of nonexistent token");
        _tokenURIs[tokenId] = _tokenURI;
    }
    
     
}

{
  "remappings": [],
  "optimizer": {
    "enabled": true,
    "runs": 200
  },
  "evmVersion": "istanbul",
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