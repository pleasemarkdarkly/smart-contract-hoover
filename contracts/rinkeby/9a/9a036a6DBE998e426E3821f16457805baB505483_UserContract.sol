// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "./tokens/nf-token-metadata.sol";
import "./ownership/ownable.sol";
import "./store/store.sol";

/**
 * @dev This is an example contract implementation of NFToken with metadata extension.
 */
contract UserContract is NFTokenMetadata, Ownable, Store {
    /**
     * @dev Contract constructor. Sets metadata extension `name` and `symbol`.
     */
    constructor(string memory contractName, string memory contractSymbol) {
        nftName = contractName;
        nftSymbol = contractSymbol;
    }

    /**
     * @dev Mints a new NFT.
     * @param _to The address that will own the minted NFT.
     * @param _tokenId of the NFT to be minted by the msg.sender.
     * @param _uri String representing RFC 3986 URI.
     */
    function mint(
        address _to,
        uint256 _tokenId,
        string calldata _uri
    ) external onlyOwner {
        super._mint(_to, _tokenId);
        super._setTokenUri(_tokenId, _uri);
        super._push(_tokenId);
    }

    /**
     * @dev Burn an NFT.
     * @param _tokenId of the NFT to be burned by the msg.sender.
     */
    function burn(uint256 _tokenId) external onlyOwner {
        super._burn(_tokenId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Escrow {
    string constant NO_BALANCE = "003009";

    // User balances
    mapping(address => uint256) internal balances;

    // Log Deposit event
    event LogDeposit(address sender, uint256 amount);

    // Log Transfer event
    event LogTransfer(address sender, address to, uint256 amount);

    // Log Withdraw
    event LogWithdraw(address to, uint256 amount);

    // Deposit Function
    function deposit() external payable returns (bool success) {
        balances[msg.sender] += msg.value;
        emit LogDeposit(msg.sender, msg.value);
        return true;
    }

    // Transfer some ethers to someone, used to buy function
    function _transferEthersToContract(
        address _from,
        address _to,
        uint256 _value
    ) internal {
        balances[_to] += _value;
        emit LogTransfer(_from, _to, _value);
    }

    // Withdraw all ethers
    function withdrawAll(address payable to) external returns (bool success) {
        require(balances[to] != 0, NO_BALANCE);
        to.transfer(balances[to]);
        emit LogWithdraw(to, balances[to]);
        balances[to] = 0;
        return true;
    }

    // Get balance
    function getBalance(address _owner) external view returns (uint256) {
        return balances[_owner];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

/**
 * @dev The contract has an owner address, and provides basic authorization control whitch
 * simplifies the implementation of user permissions. This contract is based on the source code at:
 * https://github.com/OpenZeppelin/openzeppelin-solidity/blob/master/contracts/ownership/Ownable.sol
 */
contract Ownable {
    /**
     * @dev Error constants.
     */
    string public constant NOT_CURRENT_OWNER = "018001";
    string public constant CANNOT_TRANSFER_TO_ZERO_ADDRESS = "018002";

    /**
     * @dev Current owner address.
     */
    address public owner;

    /**
     * @dev An event which is triggered when the owner is changed.
     * @param previousOwner The address of the previous owner.
     * @param newOwner The address of the new owner.
     */
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev The constructor sets the original `owner` of the contract to the sender account.
     */
    constructor() {
        owner = msg.sender;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, NOT_CURRENT_OWNER);
        _;
    }

    /**
     * @dev Allows the current owner to transfer control of the contract to a newOwner.
     * @param _newOwner The address to transfer ownership to.
     */
    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), CANNOT_TRANSFER_TO_ZERO_ADDRESS);
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../escrow/escrow.sol";
import "../tokens/nf-token-metadata.sol";

contract Store is Escrow, NFTokenMetadata {
    NFToken nfToken;

    // Error Price should not be 0
    string constant ZERO_PRICE = "003010";

    // Error item is not on sale
    string constant ITEM_IS_NOT_ON_SALE = "003011";

    // Error Money is not as same as price
    string constant INSUFFICIENT_FUNDS = "003012";

    // Items on sale. (tokenId: isOnSale)
    mapping(uint256 => bool) internal itemOnSale;

    // Items Price
    mapping(uint256 => uint256) internal itemOnSalePrice;

    /** @notice Log for a user that put a token on sale.
     * @param owner token owner
     * @param token The token id.
     * @param price The token price.
     */
    event LogPutItemOnSale(address owner, uint256 token, uint256 price);

    /** @notice Log for a user that put a token out from sale.
     * @param owner token owner
     * @param token The token id.
     */
    event LogTakeOutTokenFromSale(address owner, uint256 token);

    /** @notice Put a token on sale.
     * @dev Throws error unless sender is the owner of the token or operator, the token is valid,
     * and price is not 0 ethers
     * @param owner token owner
     * @param token The token id.
     * @param price The token price in wei.
     */
    function putItemOnSale(
        address owner,
        uint256 token,
        uint256 price
    ) external validNFToken(token) canOperate(token) returns (bool success) {
        require(owner == nfToken.ownerOf(token), NOT_OWNER);
        require(owner != address(0), ZERO_ADDRESS);
        require(price > 0, ZERO_PRICE);

        // Set token on sale to true
        itemOnSale[token] = true;
        // Set token price
        itemOnSalePrice[token] = price;
        emit LogPutItemOnSale(owner, token, price);
        return true;
    }

    /** @notice Check if token is on sale.
     * @dev Throws error unless the token is valid.
     * @param _tokenId token id
     */
    function isTokenOnSale(uint256 _tokenId)
        external
        view
        validNFToken(_tokenId)
        returns (bool status)
    {
        return itemOnSale[_tokenId];
    }

    /** @notice Take out a token from sale.
     * @dev Throws error unless sender is the owner of the token or operator, the token is valid,
     * and price is not 0 ethers
     * @param owner token owner
     * @param token The token id.
     */
    function takeOutTokenFromSale(address owner, uint256 token)
        external
        validNFToken(token)
        canOperate(token)
        returns (bool success)
    {
        require(owner != address(0), ZERO_ADDRESS);

        // Delete token from map
        delete itemOnSale[token];
        // Delete token price
        delete itemOnSalePrice[token];
        emit LogTakeOutTokenFromSale(owner, token);
        return true;
    }

    function buyToken(address _buyer, uint256 _token)
        external
        payable
        validNFToken(_token)
        returns (bool success)
    {
        require(_buyer != address(0), ZERO_ADDRESS);
        require(itemOnSale[_token], ITEM_IS_NOT_ON_SALE);
        require(msg.value >= itemOnSalePrice[_token], INSUFFICIENT_FUNDS);

        // Create an NFToken Contract variable
        address seller = nfToken.ownerOf(_token);

        // Price in wei
        uint256 priceInWei = itemOnSalePrice[_token] * (1 wei);

        // Transfer ethers to contract
        super._transferEthersToContract(_buyer, seller, priceInWei);
        // Delete token from map
        delete itemOnSale[_token];
        // Delete token price
        delete itemOnSalePrice[_token];
        // Transfer Token to the buyer
        super._transfer(_buyer, _token);
        // Returns true
        return true;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

/**
 * @dev Optional metadata extension for ERC-721 non-fungible token standard.
 * See https://github.com/ethereum/EIPs/blob/master/EIPS/eip-721.md.
 */
interface ERC721Metadata {
    /**
     * @dev Returns a descriptive name for a collection of NFTs in this contract.
     * @return _name Representing name.
     */
    function name() external view returns (string memory _name);

    /**
     * @dev Returns a abbreviated name for a collection of NFTs in this contract.
     * @return _symbol Representing symbol.
     */
    function symbol() external view returns (string memory _symbol);

    /**
     * @dev Returns a distinct Uniform Resource Identifier (URI) for a given asset. It Throws if
     * `_tokenId` is not a valid NFT. URIs are defined in RFC3986. The URI may point to a JSON file
     * that conforms to the "ERC721 Metadata JSON Schema".
     * @return URI of _tokenId.
     */
    function tokenURI(uint256 _tokenId) external view returns (string memory);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

/**
 * @dev ERC-721 interface for accepting safe transfers.
 * See https://github.com/ethereum/EIPs/blob/master/EIPS/eip-721.md.
 */
interface ERC721TokenReceiver {
    /**
     * @dev Handle the receipt of a NFT. The ERC721 smart contract calls this function on the
     * recipient after a `transfer`. This function MAY throw to revert and reject the transfer. Return
     * of other than the magic value MUST result in the transaction being reverted.
     * Returns `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))` unless throwing.
     * @notice The contract address is always the message sender. A wallet/broker/auction application
     * MUST implement the wallet interface if it will accept safe transfers.
     * @param _operator The address which called `safeTransferFrom` function.
     * @param _from The address which previously owned the token.
     * @param _tokenId The NFT identifier which is being transferred.
     * @param _data Additional data with no specified format.
     * @return Returns `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`.
     */
    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes calldata _data
    ) external returns (bytes4);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

/**
 * @dev ERC-721 non-fungible token standard.
 * See https://github.com/ethereum/EIPs/blob/master/EIPS/eip-721.md.
 */
interface ERC721 {
    /**
     * @dev Emits when ownership of any NFT changes by any mechanism. This event emits when NFTs are
     * created (`from` == 0) and destroyed (`to` == 0). Exception: during contract creation, any
     * number of NFTs may be created and assigned without emitting Transfer. At the time of any
     * transfer, the approved address for that NFT (if any) is reset to none.
     */
    event Transfer(
        address indexed _from,
        address indexed _to,
        uint256 indexed _tokenId
    );

    /**
     * @dev This emits when the approved address for an NFT is changed or reaffirmed. The zero
     * address indicates there is no approved address. When a Transfer event emits, this also
     * indicates that the approved address for that NFT (if any) is reset to none.
     */
    event Approval(
        address indexed _owner,
        address indexed _approved,
        uint256 indexed _tokenId
    );

    /**
     * @dev This emits when an operator is enabled or disabled for an owner. The operator can manage
     * all NFTs of the owner.
     */
    event ApprovalForAll(
        address indexed _owner,
        address indexed _operator,
        bool _approved
    );

    /**
     * @dev Transfers the ownership of an NFT from one address to another address.
     * @notice Throws unless `msg.sender` is the current owner, an authorized operator, or the
     * approved address for this NFT. Throws if `_from` is not the current owner. Throws if `_to` is
     * the zero address. Throws if `_tokenId` is not a valid NFT. When transfer is complete, this
     * function checks if `_to` is a smart contract (code size > 0). If so, it calls
     * `onERC721Received` on `_to` and throws if the return value is not
     * `bytes4(keccak256("onERC721Received(address,uint256,bytes)"))`.
     * @param _from The current owner of the NFT.
     * @param _to The new owner.
     * @param _tokenId The NFT to transfer.
     * @param _data Additional data with no specified format, sent in call to `_to`.
     */
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _tokenId,
        bytes calldata _data
    ) external;

    /**
     * @dev Transfers the ownership of an NFT from one address to another address.
     * @notice This works identically to the other function with an extra data parameter, except this
     * function just sets data to ""
     * @param _from The current owner of the NFT.
     * @param _to The new owner.
     * @param _tokenId The NFT to transfer.
     */
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _tokenId
    ) external;

    /**
     * @dev Throws unless `msg.sender` is the current owner, an authorized operator, or the approved
     * address for this NFT. Throws if `_from` is not the current owner. Throws if `_to` is the zero
     * address. Throws if `_tokenId` is not a valid NFT.
     * @notice The caller is responsible to confirm that `_to` is capable of receiving NFTs or else
     * they mayb be permanently lost.
     * @param _from The current owner of the NFT.
     * @param _to The new owner.
     * @param _tokenId The NFT to transfer.
     */
    function transferFrom(
        address _from,
        address _to,
        uint256 _tokenId
    ) external;

    /**
     * @dev Set or reaffirm the approved address for an NFT.
     * @notice The zero address indicates there is no approved address. Throws unless `msg.sender` is
     * the current NFT owner, or an authorized operator of the current owner.
     * @param _approved The new approved NFT controller.
     * @param _tokenId The NFT to approve.
     */
    function approve(address _approved, uint256 _tokenId) external;

    /**
     * @dev Enables or disables approval for a third party ("operator") to manage all of
     * `msg.sender`'s assets. It also emits the ApprovalForAll event.
     * @notice The contract MUST allow multiple operators per owner.
     * @param _operator Address to add to the set of authorized operators.
     * @param _approved True if the operators is approved, false to revoke approval.
     */
    function setApprovalForAll(address _operator, bool _approved) external;

    /**
     * @dev Returns the number of NFTs owned by `_owner`. NFTs assigned to the zero address are
     * considered invalid, and this function throws for queries about the zero address.
     * @param _owner Address for whom to query the balance.
     * @return Balance of _owner.
     */
    function balanceOf(address _owner) external view returns (uint256);

    /**
     * @dev Returns the address of the owner of the NFT. NFTs assigned to zero address are considered
     * invalid, and queries about them do throw.
     * @param _tokenId The identifier for an NFT.
     * @return Address of _tokenId owner.
     */
    function ownerOf(uint256 _tokenId) external view returns (address);

    /**
     * @dev Get the approved address for a single NFT.
     * @notice Throws if `_tokenId` is not a valid NFT.
     * @param _tokenId The NFT to find the approved address for.
     * @return Address that _tokenId is approved for.
     */
    function getApproved(uint256 _tokenId) external view returns (address);

    /**
     * @dev Returns true if `_operator` is an approved operator for `_owner`, false otherwise.
     * @param _owner The address that owns the NFTs.
     * @param _operator The address that acts on behalf of the owner.
     * @return True if approved for all, false otherwise.
     */
    function isApprovedForAll(address _owner, address _operator)
        external
        view
        returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "./nf-token.sol";
import "./erc721-metadata.sol";

/**
 * @dev Optional metadata implementation for ERC-721 non-fungible token standard.
 */
contract NFTokenMetadata is NFToken, ERC721Metadata {
    /**
     * @dev A descriptive name for a collection of NFTs.
     */
    string internal nftName;

    /**
     * @dev An abbreviated name for NFTokens.
     */
    string internal nftSymbol;

    /**
     * @dev Mapping from NFT ID to metadata uri.
     */
    mapping(uint256 => string) internal idToUri;

    /**
     * @dev Array of all NFT IDs.
     */
    uint256[] internal mintedTokens;

    /**
     * @dev Contract constructor.
     * @notice When implementing this contract don't forget to set nftName and nftSymbol.
     */
    constructor() {
        supportedInterfaces[0x5b5e139f] = true; // ERC721Metadata
    }

    /**
     * @dev Returns a descriptive name for a collection of NFTokens.
     * @return _name Representing name.
     */
    function name() external view override returns (string memory _name) {
        _name = nftName;
    }

    /**
     * @dev Returns an abbreviated name for NFTokens.
     * @return _symbol Representing symbol.
     */
    function symbol() external view override returns (string memory _symbol) {
        _symbol = nftSymbol;
    }

    /**
     * @dev Returns the count of all existing NFTokens.
     * @return Total supply of NFTs.
     */
    function totalToken() external view returns (uint256) {
        return mintedTokens.length;
    }

    /**
     * @dev Push NFT token to array.
     * @param _tokenId Id for which we want to push.
     */
    function _push(uint256 _tokenId) internal validNFToken(_tokenId) {
        mintedTokens.push(_tokenId);
    }

    /**
     * @dev A distinct URI (RFC 3986) for a given NFT.
     * @param _tokenId Id for which we want uri.
     * @return URI of _tokenId.
     */
    function tokenURI(uint256 _tokenId)
        external
        view
        override
        validNFToken(_tokenId)
        returns (string memory)
    {
        return idToUri[_tokenId];
    }

    /**
     * @dev Burns a NFT.
     * @notice This is an internal function which should be called from user-implemented external
     * burn function. Its purpose is to show and properly initialize data structures when using this
     * implementation. Also, note that this burn implementation allows the minter to re-mint a burned
     * NFT.
     * @param _tokenId ID of the NFT to be burned.
     */
    function _burn(uint256 _tokenId) internal virtual override {
        super._burn(_tokenId);

        if (bytes(idToUri[_tokenId]).length != 0) {
            delete idToUri[_tokenId];
        }
    }

    /**
     * @dev Set a distinct URI (RFC 3986) for a given NFT ID.
     * @notice This is an internal function which should be called from user-implemented external
     * function. Its purpose is to show and properly initialize data structures when using this
     * implementation.
     * @param _tokenId Id for which we want URI.
     * @param _uri String representing RFC 3986 URI.
     */
    function _setTokenUri(uint256 _tokenId, string memory _uri)
        internal
        validNFToken(_tokenId)
    {
        idToUri[_tokenId] = _uri;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "./erc721.sol";
import "./erc721-token-receiver.sol";
import "../utils/supports-interface.sol";
import "../utils/address-utils.sol";

/**
 * @dev Implementation of ERC-721 non-fungible token standard.
 */
contract NFToken is ERC721, SupportsInterface {
    using AddressUtils for address;

    /**
     * @dev List of revert message codes. Implementing dApp should handle showing the correct message.
     * Based on 0xcert framework error codes.
     */
    string constant ZERO_ADDRESS = "003001";
    string constant NOT_VALID_NFT = "003002";
    string constant NOT_OWNER_OR_OPERATOR = "003003";
    string constant NOT_OWNER_APPROVED_OR_OPERATOR = "003004";
    string constant NOT_ABLE_TO_RECEIVE_NFT = "003005";
    string constant NFT_ALREADY_EXISTS = "003006";
    string constant NOT_OWNER = "003007";
    string constant IS_OWNER = "003008";

    /**
     * @dev Magic value of a smart contract that can recieve NFT.
     * Equal to: bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")).
     */
    bytes4 internal constant MAGIC_ON_ERC721_RECEIVED = 0x150b7a02;

    /**
     * @dev A mapping from NFT ID to the address that owns it.
     */
    mapping(uint256 => address) internal idToOwner;

    /**
     * @dev Mapping from NFT ID to approved address.
     */
    mapping(uint256 => address) internal idToApproval;

    /**
     * @dev Mapping from owner address to count of his tokens.
     */
    mapping(address => uint256) private ownerToNFTokenCount;

    /**
     * @dev Mapping from owner address to mapping of operator addresses.
     */
    mapping(address => mapping(address => bool)) internal ownerToOperators;

    /**
     * @dev Guarantees that the msg.sender is an owner or operator of the given NFT.
     * @param _tokenId ID of the NFT to validate.
     */
    modifier canOperate(uint256 _tokenId) {
        address tokenOwner = idToOwner[_tokenId];
        require(
            tokenOwner == msg.sender ||
                ownerToOperators[tokenOwner][msg.sender],
            NOT_OWNER_OR_OPERATOR
        );
        _;
    }

    /**
     * @dev Guarantees that the msg.sender is allowed to transfer NFT.
     * @param _tokenId ID of the NFT to transfer.
     */
    modifier canTransfer(uint256 _tokenId) {
        address tokenOwner = idToOwner[_tokenId];
        require(
            tokenOwner == msg.sender ||
                idToApproval[_tokenId] == msg.sender ||
                ownerToOperators[tokenOwner][msg.sender],
            NOT_OWNER_APPROVED_OR_OPERATOR
        );
        _;
    }

    /**
     * @dev Guarantees that _tokenId is a valid Token.
     * @param _tokenId ID of the NFT to validate.
     */
    modifier validNFToken(uint256 _tokenId) {
        require(idToOwner[_tokenId] != address(0), NOT_VALID_NFT);
        _;
    }

    /**
     * @dev Contract constructor.
     */
    constructor() {
        supportedInterfaces[0x80ac58cd] = true; // ERC721
    }

    /**
     * @dev Transfers the ownership of an NFT from one address to another address. This function can
     * be changed to payable.
     * @notice Throws unless `msg.sender` is the current owner, an authorized operator, or the
     * approved address for this NFT. Throws if `_from` is not the current owner. Throws if `_to` is
     * the zero address. Throws if `_tokenId` is not a valid NFT. When transfer is complete, this
     * function checks if `_to` is a smart contract (code size > 0). If so, it calls
     * `onERC721Received` on `_to` and throws if the return value is not
     * `bytes4(keccak256("onERC721Received(address,uint256,bytes)"))`.
     * @param _from The current owner of the NFT.
     * @param _to The new owner.
     * @param _tokenId The NFT to transfer.
     * @param _data Additional data with no specified format, sent in call to `_to`.
     */
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _tokenId,
        bytes calldata _data
    ) external override {
        _safeTransferFrom(_from, _to, _tokenId, _data);
    }

    /**
     * @dev Transfers the ownership of an NFT from one address to another address. This function can
     * be changed to payable.
     * @notice This works identically to the other function with an extra data parameter, except this
     * function just sets data to ""
     * @param _from The current owner of the NFT.
     * @param _to The new owner.
     * @param _tokenId The NFT to transfer.
     */
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _tokenId
    ) external override {
        _safeTransferFrom(_from, _to, _tokenId, "");
    }

    /**
     * @dev Throws unless `msg.sender` is the current owner, an authorized operator, or the approved
     * address for this NFT. Throws if `_from` is not the current owner. Throws if `_to` is the zero
     * address. Throws if `_tokenId` is not a valid NFT. This function can be changed to payable.
     * @notice The caller is responsible to confirm that `_to` is capable of receiving NFTs or else
     * they maybe be permanently lost.
     * @param _from The current owner of the NFT.
     * @param _to The new owner.
     * @param _tokenId The NFT to transfer.
     */
    function transferFrom(
        address _from,
        address _to,
        uint256 _tokenId
    ) external override canTransfer(_tokenId) validNFToken(_tokenId) {
        address tokenOwner = idToOwner[_tokenId];
        require(tokenOwner == _from, NOT_OWNER);
        require(_to != address(0), ZERO_ADDRESS);

        _transfer(_to, _tokenId);
    }

    /**
     * @dev Set or reaffirm the approved address for an NFT. This function can be changed to payable.
     * @notice The zero address indicates there is no approved address. Throws unless `msg.sender` is
     * the current NFT owner, or an authorized operator of the current owner.
     * @param _approved Address to be approved for the given NFT ID.
     * @param _tokenId ID of the token to be approved.
     */
    function approve(address _approved, uint256 _tokenId)
        external
        override
        canOperate(_tokenId)
        validNFToken(_tokenId)
    {
        address tokenOwner = idToOwner[_tokenId];
        require(_approved != tokenOwner, IS_OWNER);

        idToApproval[_tokenId] = _approved;
        emit Approval(tokenOwner, _approved, _tokenId);
    }

    /**
     * @dev Enables or disables approval for a third party ("operator") to manage all of
     * `msg.sender`'s assets. It also emits the ApprovalForAll event.
     * @notice This works even if sender doesn't own any tokens at the time.
     * @param _operator Address to add to the set of authorized operators.
     * @param _approved True if the operators is approved, false to revoke approval.
     */
    function setApprovalForAll(address _operator, bool _approved)
        external
        override
    {
        ownerToOperators[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    /**
     * @dev Returns the number of NFTs owned by `_owner`. NFTs assigned to the zero address are
     * considered invalid, and this function throws for queries about the zero address.
     * @param _owner Address for whom to query the balance.
     * @return Balance of _owner.
     */
    function balanceOf(address _owner)
        external
        view
        override
        returns (uint256)
    {
        require(_owner != address(0), ZERO_ADDRESS);
        return _getOwnerNFTCount(_owner);
    }

    /**
     * @dev Returns the address of the owner of the NFT. NFTs assigned to zero address are considered
     * invalid, and queries about them do throw.
     * @param _tokenId The identifier for an NFT.
     * @return _owner Address of _tokenId owner.
     */
    function ownerOf(uint256 _tokenId)
        external
        view
        override
        returns (address _owner)
    {
        _owner = idToOwner[_tokenId];
        require(_owner != address(0), NOT_VALID_NFT);
    }

    /**
     * @dev Get the approved address for a single NFT.
     * @notice Throws if `_tokenId` is not a valid NFT.
     * @param _tokenId ID of the NFT to query the approval of.
     * @return Address that _tokenId is approved for.
     */
    function getApproved(uint256 _tokenId)
        external
        view
        override
        validNFToken(_tokenId)
        returns (address)
    {
        return idToApproval[_tokenId];
    }

    /**
     * @dev Checks if `_operator` is an approved operator for `_owner`.
     * @param _owner The address that owns the NFTs.
     * @param _operator The address that acts on behalf of the owner.
     * @return True if approved for all, false otherwise.
     */
    function isApprovedForAll(address _owner, address _operator)
        external
        view
        override
        returns (bool)
    {
        return ownerToOperators[_owner][_operator];
    }

    /**
     * @dev Actually preforms the transfer.
     * @notice Does NO checks.
     * @param _to Address of a new owner.
     * @param _tokenId The NFT that is being transferred.
     */
    function _transfer(address _to, uint256 _tokenId) internal {
        address from = idToOwner[_tokenId];
        _clearApproval(_tokenId);

        _removeNFToken(from, _tokenId);
        _addNFToken(_to, _tokenId);

        emit Transfer(from, _to, _tokenId);
    }

    /**
     * @dev Mints a new NFT.
     * @notice This is an internal function which should be called from user-implemented external
     * mint function. Its purpose is to show and properly initialize data structures when using this
     * implementation.
     * @param _to The address that will own the minted NFT.
     * @param _tokenId of the NFT to be minted by the msg.sender.
     */
    function _mint(address _to, uint256 _tokenId) internal virtual {
        require(_to != address(0), ZERO_ADDRESS);
        require(idToOwner[_tokenId] == address(0), NFT_ALREADY_EXISTS);

        _addNFToken(_to, _tokenId);

        emit Transfer(address(0), _to, _tokenId);
    }

    /**
     * @dev Burns a NFT.
     * @notice This is an internal function which should be called from user-implemented external burn
     * function. Its purpose is to show and properly initialize data structures when using this
     * implementation. Also, note that this burn implementation allows the minter to re-mint a burned
     * NFT.
     * @param _tokenId ID of the NFT to be burned.
     */
    function _burn(uint256 _tokenId) internal virtual validNFToken(_tokenId) {
        address tokenOwner = idToOwner[_tokenId];
        _clearApproval(_tokenId);
        _removeNFToken(tokenOwner, _tokenId);
        emit Transfer(tokenOwner, address(0), _tokenId);
    }

    /**
     * @dev Removes a NFT from owner.
     * @notice Use and override this function with caution. Wrong usage can have serious consequences.
     * @param _from Address from wich we want to remove the NFT.
     * @param _tokenId Which NFT we want to remove.
     */
    function _removeNFToken(address _from, uint256 _tokenId) internal virtual {
        require(idToOwner[_tokenId] == _from, NOT_OWNER);
        ownerToNFTokenCount[_from] = ownerToNFTokenCount[_from] - 1;
        delete idToOwner[_tokenId];
    }

    /**
     * @dev Assignes a new NFT to owner.
     * @notice Use and override this function with caution. Wrong usage can have serious consequences.
     * @param _to Address to wich we want to add the NFT.
     * @param _tokenId Which NFT we want to add.
     */
    function _addNFToken(address _to, uint256 _tokenId) internal virtual {
        require(idToOwner[_tokenId] == address(0), NFT_ALREADY_EXISTS);

        idToOwner[_tokenId] = _to;
        ownerToNFTokenCount[_to] = ownerToNFTokenCount[_to] + 1;
    }

    /**
     * @dev Helper function that gets NFT count of owner. This is needed for overriding in enumerable
     * extension to remove double storage (gas optimization) of owner nft count.
     * @param _owner Address for whom to query the count.
     * @return Number of _owner NFTs.
     */
    function _getOwnerNFTCount(address _owner)
        internal
        view
        virtual
        returns (uint256)
    {
        return ownerToNFTokenCount[_owner];
    }

    /**
     * @dev Actually perform the safeTransferFrom.
     * @param _from The current owner of the NFT.
     * @param _to The new owner.
     * @param _tokenId The NFT to transfer.
     * @param _data Additional data with no specified format, sent in call to `_to`.
     */
    function _safeTransferFrom(
        address _from,
        address _to,
        uint256 _tokenId,
        bytes memory _data
    ) private canTransfer(_tokenId) validNFToken(_tokenId) {
        address tokenOwner = idToOwner[_tokenId];
        require(tokenOwner == _from, NOT_OWNER);
        require(_to != address(0), ZERO_ADDRESS);

        _transfer(_to, _tokenId);

        if (_to.isContract()) {
            bytes4 retval =
                ERC721TokenReceiver(_to).onERC721Received(
                    msg.sender,
                    _from,
                    _tokenId,
                    _data
                );
            require(
                retval == MAGIC_ON_ERC721_RECEIVED,
                NOT_ABLE_TO_RECEIVE_NFT
            );
        }
    }

    /**
     * @dev Clears the current approval of a given NFT ID.
     * @param _tokenId ID of the NFT to be transferred.
     */
    function _clearApproval(uint256 _tokenId) private {
        if (idToApproval[_tokenId] != address(0)) {
            delete idToApproval[_tokenId];
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

/**
 * @dev Utility library of inline functions on addresses.
 * @notice Based on:
 * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Address.sol
 * Requires EIP-1052.
 */
library AddressUtils {
    /**
     * @dev Returns whether the target address is a contract.
     * @param _addr Address to check.
     * @return addressCheck True if _addr is a contract, false if not.
     */
    function isContract(address _addr)
        internal
        view
        returns (bool addressCheck)
    {
        // This method relies in extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        // According to EIP-1052, 0x0 is the value returned for not-yet created accounts
        // and 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 is returned
        // for accounts without code, i.e. `keccak256('')`
        bytes32 codehash;
        bytes32 accountHash =
            0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        assembly {
            codehash := extcodehash(_addr)
        } // solhint-disable-line
        addressCheck = (codehash != 0x0 && codehash != accountHash);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

/**
 * @dev A standard for detecting smart contract interfaces.
 * See: https://eips.ethereum.org/EIPS/eip-165.
 */
interface ERC165 {
    /**
     * @dev Checks if the smart contract includes a specific interface.
     * This function uses less than 30,000 gas.
     * @param _interfaceID The interface identifier, as specified in ERC-165.
     * @return True if _interfaceID is supported, false otherwise.
     */
    function supportsInterface(bytes4 _interfaceID)
        external
        view
        returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "./erc165.sol";

/**
 * @dev Implementation of standard for detect smart contract interfaces.
 */
contract SupportsInterface is ERC165 {
    /**
     * @dev Mapping of supported intefraces. You must not set element 0xffffffff to true.
     */
    mapping(bytes4 => bool) internal supportedInterfaces;

    /**
     * @dev Contract constructor.
     */
    constructor() {
        supportedInterfaces[0x01ffc9a7] = true; // ERC165
    }

    /**
     * @dev Function to check which interfaces are suported by this contract.
     * @param _interfaceID Id of the interface.
     * @return True if _interfaceID is supported, false otherwise.
     */
    function supportsInterface(bytes4 _interfaceID)
        external
        view
        override
        returns (bool)
    {
        return supportedInterfaces[_interfaceID];
    }
}

{
  "remappings": [],
  "optimizer": {
    "enabled": false,
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