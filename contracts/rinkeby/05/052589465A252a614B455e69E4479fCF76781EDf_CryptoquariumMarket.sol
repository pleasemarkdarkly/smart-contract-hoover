// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "./fish/AbstractFishMarketplace.sol";

contract CryptoquariumMarket is AbstractFishMarketplace {
    constructor (address _fishNFT)
    AbstractFishMarketplace(10, 1 ether, _fishNFT) {}
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./IFishMarketplace.sol";
import "./IFishNFT.sol";

abstract contract AbstractFishMarketplace is IFishMarketplace, Ownable {
    uint internal percentsFee = 10;
    uint internal defaultPrice = 1 ether;
    Lot[] public lots;
    mapping(uint => uint) public fishToIndex;
    IFishNFT fishNFT;

    modifier fishOwnerOrApproved(uint fishId) {
        address spender = _msgSender();
        address owner = fishNFT.ownerOf(fishId);

        require(address(fishNFT) == spender || spender == owner
        || fishNFT.getApproved(fishId) == spender
            || fishNFT.isApprovedForAll(owner, spender), "Not Allowed!");

        _;
    }

    modifier isFish() {
        require(address(fishNFT) == _msgSender(), "Not Allowed!");

        _;
    }

    constructor(uint _percentsFee, uint _defaultPrice, address _fishNFT) {
        percentsFee = _percentsFee;
        defaultPrice = _defaultPrice;
        fishNFT = IFishNFT(_fishNFT);
    }

    function totalLots() external view returns (uint) {
        return lots.length;
    }

    function buy(uint fishId) payable external {
        address payable buyer = payable(_msgSender());
        uint lotIdx = fishToIndex[fishId];

        Lot memory lot = lots[lotIdx];
        uint amount = msg.value;
        uint price = lot.price - lot.feeAmount;

        require(amount >= price, "Not enough sent");

        string memory artistName = fishNFT.fishArtist(fishId);
        ByArtist.Artist memory artist = fishNFT.artists(artistName);

        address from = lot.seller;
        address payable paymentTo = payable(lot.seller);
        if (from == address(0)) {
            // Selling from the platform
            from = address(this);
            paymentTo = artist.paymentsAddress;
        }

        removeLot(fishId);

        // transfers at the end
        paymentTo.transfer(price);
        artist.feeCollectionAddress.transfer(amount - price);
        fishNFT.unlockAndTransfer(buyer, fishId);
    }

    function sell(uint fishId, uint price) fishOwnerOrApproved(fishId) public {
        uint lotIdx = lots.length;
        fishToIndex[fishId] = lotIdx;

        uint feeAmount = price * percentsFee / 100;
        uint price = price + feeAmount;
        lots.push(Lot(
                fishId,
                price,
                feeAmount,
                _msgSender() == address(fishNFT) ? address(0) : _msgSender())
        );

        emit FishSelling(fishId, price);
        fishNFT.lock(fishId);
    }

    function cancelSelling(uint fishId) fishOwnerOrApproved(fishId) public {
        uint lotIdx = fishToIndex[fishId];
        Lot storage lot = lots[lotIdx];
        require(lot.seller == _msgSender(), "Not a seller");

        removeLot(fishId);
        emit FishNoLongerForSale(fishId);
        fishNFT.unlock(fishId);
    }

    function sellMultiple(uint fishIdFrom, uint fishIdTo) isFish external override {
        uint price = defaultPrice;

        for (uint fishId = fishIdFrom; fishId < fishIdTo; ++fishId) {
            uint lotIdx = lots.length;
            fishToIndex[fishId] = lotIdx;

            lots.push(Lot(fishId, price, 0, address(0)));
        }

        emit ConsecutiveFishSelling(fishIdFrom, fishIdTo, price);
    }

    function setDefaultPrice(uint _defaultPrice) onlyOwner external {
        defaultPrice = _defaultPrice;
    }

    function setPercentsFee(uint _percentsFee) onlyOwner external {
        percentsFee = _percentsFee;
    }

    // -=[ IERC721Receiver implementation ]=-
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
    external override returns (bytes4) {
        sell(tokenId, defaultPrice);
        return this.onERC721Received.selector;
    }

    function removeLot(uint256 fishId) private {
        // To prevent a gap in from's tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint256 lastTokenIndex = lots.length - 1;
        uint256 tokenIndex = fishToIndex[fishId];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (tokenIndex != lastTokenIndex) {
            uint lastTokenId = lots[lastTokenIndex].fishId;

            lots[tokenIndex] = lots[lastTokenIndex];
            // Move the last token to the slot of the to-delete token
            fishToIndex[lastTokenId] = tokenIndex;
            // Update the moved token's index
        }

        // This also deletes the contents at the last position of the array
        delete fishToIndex[fishId];
        delete lots[lastTokenIndex];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../libs/Utils.sol";

abstract contract ByArtist is Ownable {
    struct Artist {
        string name;
        address payable paymentsAddress;
        address payable feeCollectionAddress;
    }

    mapping(string => Artist) internal _artists;

    function updateArtist(string memory name, address payable paymentsAddress, address payable feeCollectionAddress)
    onlyOwner external {
        Artist storage artist = _artists[name];
        artist.name = name;
        artist.feeCollectionAddress = feeCollectionAddress;
        artist.paymentsAddress = paymentsAddress;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IFishMarketplace is IERC721Receiver {
    // --[ Events ]--
    event ConsecutiveFishSelling(uint indexed fromFishId, uint toFishId, uint price);
    event FishSelling(uint indexed fishId, uint price);
    event FishBought(uint indexed fishId, uint value, address indexed fromAddress, address indexed toAddress);
    event FishNoLongerForSale(uint indexed fishId);

    struct Lot {
        uint fishId;
        uint price;
        uint feeAmount;
        address seller;
    }

    function sellMultiple(uint fishIdFrom, uint fishIdTo) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "./Artist.sol";

interface IFishNFT is IERC721, IERC721Metadata {
    struct Fish {
        string name;
        uint tokenId;
        string artist;
        string image;
    }

    // --[ Methods ]--
    function fishArtist(uint fishId) external view returns (string memory);
    function artists(string memory name) external view returns (ByArtist.Artist memory);
    function lock(uint fishId) external;
    function unlock(uint fishId) external;
    function unlockAndTransfer(address buyer, uint fishId) external;
    function fishLocked(uint fishId) external view returns(bool);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

library Utils {
    function uint2str(uint _i) internal pure returns (string memory _uintAsString) {
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
        uint k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function concat(string memory s1, string memory s2)
    internal pure returns (string memory) {
        return string(abi.encodePacked(s1, s2));
    }

    function concat(string memory s1, string memory s2, string memory s3)
    internal pure returns (string memory) {
        return string(abi.encodePacked(s1, s2, s3));
    }

    function concat(string memory s1, string memory s2, string memory s3, string memory s4)
    internal pure returns (string memory) {
        return string(abi.encodePacked(s1, s2, s3, s4));
    }

    function concat(string memory s1,
        string memory s2,
        string memory s3,
        string memory s4,
        string memory s5
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(s1, s2, s3, s4, s5));
    }

    function stringToBytes32(string memory source) internal pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }
        assembly {
            result := mload(add(source, 32))
        }
    }

    function bytes32ToString(bytes memory byteCode) internal pure returns (string memory stringData) {
        uint256 blank = 0; //blank 32 byte value
        uint256 length = byteCode.length;

        uint cycles = byteCode.length / 0x20;
        uint requiredAlloc = length;

        if (length % 0x20 > 0) //optimise copying the final part of the bytes - to avoid looping with single byte writes
        {
            cycles++;
            requiredAlloc += 0x20; //expand memory to allow end blank, so we don't smack the next stack entry
        }

        stringData = new string(requiredAlloc);

        //copy data in 32 byte blocks
        assembly {
            let cycle := 0

            for
            {
                let mc := add(stringData, 0x20) //pointer into bytes we're writing to
                let cc := add(byteCode, 0x20)   //pointer to where we're reading from
            } lt(cycle, cycles) {
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
                cycle := add(cycle, 0x01)
            } {
                mstore(mc, mload(cc))
            }
        }

        //finally blank final bytes and shrink size (part of the optimisation to avoid looping adding blank bytes1)
        if (length % 0x20 > 0)
        {
            uint offsetStart = 0x20 + length;
            assembly
            {
                let mc := add(stringData, offsetStart)
                mstore(mc, mload(add(blank, 0x20)))
            //now shrink the memory back so the returned object is the correct size
                mstore(stringData, length)
            }
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../utils/Context.sol";
/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../../utils/introspection/IERC165.sol";

/**
 * @dev Required interface of an ERC721 compliant contract.
 */
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be have been allowed to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Usage of this method is discouraged, use {safeTransferFrom} whenever possible.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the caller.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool _approved) external;

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /**
      * @dev Safely transfers `tokenId` token from `from` to `to`.
      *
      * Requirements:
      *
      * - `from` cannot be the zero address.
      * - `to` cannot be the zero address.
      * - `tokenId` token must exist and be owned by `from`.
      * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
      * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
      *
      * Emits a {Transfer} event.
      */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title ERC721 token receiver interface
 * @dev Interface for any contract that wants to support safeTransfers
 * from ERC721 asset contracts.
 */
interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be reverted.
     *
     * The selector can be obtained in Solidity with `IERC721.onERC721Received.selector`.
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../IERC721.sol";

/**
 * @title ERC-721 Non-Fungible Token Standard, optional metadata extension
 * @dev See https://eips.ethereum.org/EIPS/eip-721
 */
interface IERC721Metadata is IERC721 {

    /**
     * @dev Returns the token collection name.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the token collection symbol.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the Uniform Resource Identifier (URI) for `tokenId` token.
     */
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
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