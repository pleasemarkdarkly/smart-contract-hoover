/**
 *Submitted for verification at Etherscan.io on 2021-06-05
*/

// File: openzeppelin-solidity/contracts/math/SafeMath.sol

pragma solidity ^0.5.0;

/**
 * @title SafeMath
 * @dev Unsigned math operations with safety checks that revert on error
 */
library SafeMath {
    /**
    * @dev Multiplies two unsigned integers, reverts on overflow.
    */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b);

        return c;
    }

    /**
    * @dev Integer division of two unsigned integers truncating the quotient, reverts on division by zero.
    */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
    * @dev Subtracts two unsigned integers, reverts on overflow (i.e. if subtrahend is greater than minuend).
    */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a);
        uint256 c = a - b;

        return c;
    }

    /**
    * @dev Adds two unsigned integers, reverts on overflow.
    */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a);

        return c;
    }

    /**
    * @dev Divides two unsigned integers and returns the remainder (unsigned integer modulo),
    * reverts when dividing by zero.
    */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0);
        return a % b;
    }
}

// File: openzeppelin-solidity/contracts/ownership/Ownable.sol

pragma solidity ^0.5.0;

/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev The Ownable constructor sets the original `owner` of the contract to the sender
     * account.
     */
    constructor () internal {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    /**
     * @return the address of the owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(isOwner());
        _;
    }

    /**
     * @return true if `msg.sender` is the owner of the contract.
     */
    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    /**
     * @dev Allows the current owner to relinquish control of the contract.
     * @notice Renouncing to ownership will leave the contract without an owner.
     * It will not be possible to call the functions with the `onlyOwner`
     * modifier anymore.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Allows the current owner to transfer control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0));
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

// File: openzeppelin-solidity/contracts/introspection/IERC165.sol

pragma solidity ^0.5.0;

/**
 * @title IERC165
 * @dev https://github.com/ethereum/EIPs/blob/master/EIPS/eip-165.md
 */
interface IERC165 {
    /**
     * @notice Query if a contract implements an interface
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @dev Interface identification is specified in ERC-165. This function
     * uses less than 30,000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// File: openzeppelin-solidity/contracts/token/ERC721/IERC721.sol

pragma solidity ^0.5.0;


/**
 * @title ERC721 Non-Fungible Token Standard basic interface
 * @dev see https://github.com/ethereum/EIPs/blob/master/EIPS/eip-721.md
 */
contract IERC721 is IERC165 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) public view returns (uint256 balance);
    function ownerOf(uint256 tokenId) public view returns (address owner);

    function approve(address to, uint256 tokenId) public;
    function getApproved(uint256 tokenId) public view returns (address operator);

    function setApprovalForAll(address operator, bool _approved) public;
    function isApprovedForAll(address owner, address operator) public view returns (bool);

    function transferFrom(address from, address to, uint256 tokenId) public;
    function safeTransferFrom(address from, address to, uint256 tokenId) public;

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public;
}

// File: openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol

pragma solidity ^0.5.0;

/**
 * @title Helps contracts guard against reentrancy attacks.
 * @author Remco Bloemen <[email protected]π.com>, Eenae <[email protected]>
 * @dev If you mark a function `nonReentrant`, you should also
 * mark it `external`.
 */
contract ReentrancyGuard {
    /// @dev counter to allow mutex lock with only one SSTORE operation
    uint256 private _guardCounter;

    constructor () internal {
        // The counter starts at one to prevent changing it from zero to a non-zero
        // value, which is a more expensive operation.
        _guardCounter = 1;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _guardCounter += 1;
        uint256 localCounter = _guardCounter;
        _;
        require(localCounter == _guardCounter);
    }
}

// File: contracts/ExodusAuction.sol

pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;






contract ExodusAuction is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    bool public globalPaused;

    uint256 public timeBuffer = 15 * 60; // extend 15 minutes after every bid made in last 15 minutes
    uint256 public minBid = 1 * 10**17; // 0.1 eth

    bytes4 constant interfaceId = 0x80ac58cd; // 721 interface id
    address public nftAddress;
    address payable public admin;

    mapping(uint256 => Auction) public auctions;
    uint256[] public tokenIds;

    struct Auction {
        bool exists;
        bool paused;
        uint256 amount;
        uint256 tokenId;
        uint256 duration;
        uint256 firstBidTime;
        uint256 reservePrice;
        uint256 adminSplit; // percentage of 100
        address creator;
        address payable proceedsRecipient;
        address payable bidder;
    }

    modifier notPaused() {
        require(!globalPaused, "Must not be paused");
        _;
    }

    event AuctionCreated(
        uint256 tokenId,
        address nftAddress,
        uint256 duration,
        uint256 reservePrice,
        address creator
    );
    event AuctionBid(
        uint256 tokenId,
        address nftAddress,
        address sender,
        uint256 value,
        uint256 timestamp,
        bool firstBid,
        bool extended
    );
    event AuctionEnded(
        uint256 tokenId,
        address nftAddress,
        address creator,
        address winner,
        uint256 amount
    );
    event AuctionCanceled(
        uint256 tokenId,
        address nftAddress,
        address creator
    );
    event UpdateAuction(
        uint256 tokenId,
        bool paused
    );

    constructor(address _nftAddress, address payable _admin) public {
        require(
            IERC165(_nftAddress).supportsInterface(interfaceId),
            "Doesn't support NFT interface"
        );
        nftAddress = _nftAddress;
        admin = _admin;
    }

    function updateNftAddress(address _nftAddress) public onlyOwner {
        require(
            IERC165(_nftAddress).supportsInterface(interfaceId),
            "Doesn't support NFT interface"
        );
        nftAddress = _nftAddress;
    }

    function updateMinBid(uint256 _minBid) public onlyOwner {
        minBid = _minBid;
    }

    function updateTimeBuffer(uint256 _timeBuffer) public onlyOwner {
        timeBuffer = _timeBuffer;
    }

    function updateAuction(uint256 tokenId, bool paused) public onlyOwner {
        require(auctions[tokenId].exists, "Auction doesn't exist");
        auctions[tokenId].paused = paused;
        emit UpdateAuction(tokenId, paused);
    }

    function createAuction(
        bool paused,
        uint256 tokenId,
        uint256 duration,
        uint256 firstBidTime,
        uint256 reservePrice,
        uint256 adminSplit, // percentage
        address payable proceedsRecipient
    ) external notPaused onlyOwner nonReentrant {
        require(!auctions[tokenId].exists, "Auction already exists");
        require(adminSplit < 100, "Percentage has to be less than 100");
        tokenIds.push(tokenId);

        auctions[tokenId].paused = paused;
        auctions[tokenId].exists = true;
        auctions[tokenId].duration = duration;
        auctions[tokenId].firstBidTime = firstBidTime;
        auctions[tokenId].reservePrice = reservePrice;

        auctions[tokenId].adminSplit = adminSplit;
        auctions[tokenId].creator = msg.sender;
        auctions[tokenId].proceedsRecipient = proceedsRecipient;

        IERC721(nftAddress).transferFrom(msg.sender, address(this), tokenId);

        emit AuctionCreated(tokenId, nftAddress, duration, reservePrice, msg.sender);
    }

    function createBid(uint256 tokenId) external payable notPaused nonReentrant {

        Auction memory auction = auctions[tokenId];

        require(auction.exists, "Auction doesn't exist");
        require(!auction.paused, "Auction paused");
        require(
            msg.value >= auction.reservePrice,
            "Must send reservePrice or more"
        );

        if (auction.firstBidTime > 0) {
            require(
                auction.firstBidTime <= block.timestamp,
            "Auction hasn't started");
        }

        require(
            auction.firstBidTime == 0 ||
                block.timestamp <
                auction.firstBidTime + auction.duration,
            "Auction expired"
        );

        uint256 lastValue = auction.amount;

        bool firstBid;
        address payable lastBidder;

        // allows for auctions with starting price of 0
        if (lastValue != 0) {
            require(msg.value > lastValue, "Must send more than last bid");
            require(
                msg.value.sub(lastValue) >= minBid,
                "Must send more than last bid by minBid Amount"
            );
            lastBidder = auction.bidder;
        } else {
            firstBid = true;
            if (auction.firstBidTime == 0) {
                auctions[tokenId].firstBidTime = block.timestamp;
            }
        }

        auctions[tokenId].amount = msg.value;
        auctions[tokenId].bidder = msg.sender;

        bool extended;
        // at this point we know that the timestamp is less than start + duration
        // we want to know by how much the timestamp is less than start + duration
        // if the difference is less than the timeBuffer, update duration to time buffer
        if (
            ( auctions[tokenId].firstBidTime.add( auction.duration ) ).sub( block.timestamp ) < timeBuffer
        ) {
            // take the difference between now and starting point, add timeBuffer and set as duration
            auctions[tokenId].duration = block.timestamp.sub(auctions[tokenId].firstBidTime).add(timeBuffer);
            extended = true;
        }

        emit AuctionBid(
            tokenId,
            nftAddress,
            msg.sender,
            msg.value,
            block.timestamp,
            firstBid,
            extended
        );
        if (!firstBid && lastValue > 0) {
            // in case the bidder is a contract that doesn't allow receiving
             (bool success, ) = lastBidder.call.value(lastValue)("");
            if (!success) {
                (success, ) = admin.call.value(lastValue)("");
                require(success, "admin (in place of lastBidder) failed to receive");
            }
        }
    }

    function endAuction(uint256 tokenId) external notPaused nonReentrant {
        
        Auction memory auction = auctions[tokenId];

        require(auction.exists, "Auction doesn't exist");
        require(!auction.paused, "Auction paused");
        require(
            uint256(auction.firstBidTime) != 0,
            "Auction hasn't begun"
        );
        require(
            block.timestamp >=
                auction.firstBidTime + auction.duration,
            "Auction hasn't completed"
        );

        address winner = auction.bidder;
        uint256 amount = auction.amount;
        address creator = auction.creator;
        uint256 adminSplit = auction.adminSplit;
        address payable proceedsRecipient = auction.proceedsRecipient;

        emit AuctionEnded(tokenId, nftAddress, creator, winner, amount);
        delete auctions[tokenId];

        IERC721(nftAddress).transferFrom(address(this), winner, tokenId);

        uint256 adminReceives = amount.mul(adminSplit).div(100);
        uint256 proceedsAmount = amount.sub(adminReceives);
        bool success;
        if (adminReceives > 0) {
            (success, ) = admin.call.value(adminReceives)("");
            require(success, "admin failed to receive");
        }

        (success, ) = proceedsRecipient.call.value(proceedsAmount)("");
        require(success, "recipient failed to receive");
    }

    function cancelAuction(uint256 tokenId) external nonReentrant {

        Auction memory auction = auctions[tokenId];

        require(auction.exists, "Auction doesn't exist");
        require(
            auction.creator == msg.sender || msg.sender == owner(),
            "Can only be called by auction creator or owner"
        );
        require(
            auction.amount == 0,
            "Can't cancel an auction once it's begun"
        );
        address creator = auction.creator;
        delete auctions[tokenId];
        IERC721(nftAddress).transferFrom(address(this), creator, tokenId);
        emit AuctionCanceled(tokenId, nftAddress, creator);
    }

    function updatePaused(bool _globalPaused) public onlyOwner {
        globalPaused = _globalPaused;
    }

    function updateAdmin(address payable _admin) public onlyOwner {
        admin = _admin;
    }
}