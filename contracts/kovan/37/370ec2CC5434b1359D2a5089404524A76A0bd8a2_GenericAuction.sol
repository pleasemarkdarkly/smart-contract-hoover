// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import {SafeMath} from '@openzeppelin/contracts/math/SafeMath.sol';
import {IERC20Permit} from './interfaces/IERC20Permit.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {AuctionBase} from './misc/AuctionBase.sol';
import {WETHBase} from './misc/WETHBase.sol';
import {DataTypes} from './libraries/DataTypes.sol';
import {Errors} from './libraries/Errors.sol';
import {VersionedInit} from './upgradeability/VersionedInit.sol';

/**
 * @title Generic Auction Contract
 *
 *
 * @dev Contract that manages interactions between NFT owners, patrons and owners.
 */
contract GenericAuction is VersionedInit, AuctionBase, WETHBase, ReentrancyGuard {
    using SafeERC20 for IERC20Permit;
    using SafeMath for uint256;

    uint256 public constant GENERICAUCTION_REVISION = 0x1;

    mapping(address => mapping(uint256 => DataTypes.GenericAuctionFullData)) internal _nftData;
    mapping(address => bool) internal _whitelisted;
    /**
     * @notice Emitted when a new auction is scheduled on a given NFT.
     *
     * @param currency The auction ERC20 currency.
     * @param nft The NFT address of the token to auction.
     * @param nftId The NFT ID of the token to auction.
     * @param startTimestamp The auction's starting timestamp.
     * @param endTimestamp The auction's ending timestamp.
     * @param startPrice The auction's starting price.
     */
    event AuctionCreated(
        address indexed currency,
        address indexed nft,
        uint256 indexed nftId,
        uint40 startTimestamp,
        uint40 endTimestamp,
        uint256 startPrice
    );

    /**
     * @notice Emitted when a new bid or outbid is created on a given NFT.
     *
     * @param nft The NFT address of the token bid on.
     * @param nftId The NFT ID of the token bid on.
     * @param bidder The bidder address.
     * @param amount The amount used to bid.
     */
    event BidSubmitted(
        address indexed nft,
        uint256 indexed nftId,
        address indexed bidder,
        uint256 amount
    );

    /**
     * @notice Emitted when an NFT is won and claimed.
     *
     * @param nft The NFT address of the token claimed.
     * @param nftId The NFT ID of the token claimed.
     * @param winner The winner of the NFT.
     */
    event WonNftClaimed(address indexed nft, uint256 indexed nftId, address indexed winner);

    /**
     * @notice Emitted when an NFT is reclaimed from an expired auction with no bids.
     *
     * @param nft The NFT address reclaimed.
     * @param nftId The NFT ID reclaimed.
     */
    event Reclaimed(address indexed nft, uint256 indexed nftId);

    /**
     * @notice Constructor sets the immutable WETH address.
     *
     * @param weth The WETH address.
     */
    constructor(address weth) WETHBase(weth) {}

    /**
     * @dev Initializes the contract.
     *
     * @param treasury The treasury to send fees to.
     * @param treasuryFeeBps The treasury fee basis points sent upon claiming and burning.
     * @param overtimeWindow The overtime window, triggers when a bid is sent within endTimestamp - overtimeWindow.
     * @param minimumAuctionDuration The minimum auction duration.
     * @param admin The administrator address to set, allows pausing.
     */
    function initialize(
        address treasury,
        uint16 treasuryFeeBps,
        uint40 overtimeWindow,
        uint40 minimumAuctionDuration,
        address admin,
        uint8 distributionCap
    ) public initializer {
        require(
            treasury != address(0) &&
                treasuryFeeBps < BPS_MAX &&
                admin != address(0) &&
                overtimeWindow < minimumAuctionDuration &&
                distributionCap > 0 &&
                distributionCap < 6,
            Errors.INVALID_INIT_PARAMS
        );

        _treasury = treasury;
        _treasuryFeeBps = treasuryFeeBps;
        _overtimeWindow = overtimeWindow;
        _minimumAuctionDuration = minimumAuctionDuration;
        _admin = admin;
        _distributionCap = distributionCap;
        _whitelisted[address(WETH)] = true;
        _paused = false;
    }

    /**
     * @notice Creates an auction on a given NFT with specified parameters. Initiator must be the owner of the NFT.
     *
     * @param nft The NFT address to auction.
     * @param nftId The NFT ID to auction.
     * @param startTimestamp The starting auction timestamp.
     * @param endTimestamp The ending auction timestamp.
     * @param startPrice The starting price for the auction.
     * @param distribution The distribution to follow upon completion
     */
    function createAuction(
        address currency,
        address nft,
        uint256 nftId,
        uint40 startTimestamp,
        uint40 endTimestamp,
        uint256 startPrice,
        DataTypes.DistributionData[] memory distribution
    ) external nonReentrant whenNotPaused {
        require(_nftData[nft][nftId].auctioner == address(0), Errors.AUCTION_EXISTS);
        require(currency != address(0), Errors.ZERO_CURRENCY);
        require(_whitelisted[currency], Errors.CURRENCY_NOT_WHITELSITED);
        require(
            distribution.length <= _distributionCap && distribution.length >= 1,
            Errors.INVALID_DISTRIBUTION_COUNT
        );
        require(
            startTimestamp > block.timestamp && endTimestamp > startTimestamp,
            Errors.INVALID_AUCTION_TIMESTAMPS
        );
        require(
            endTimestamp - startTimestamp >= _minimumAuctionDuration,
            Errors.INVALID_AUCTION_DURATION
        );

        uint256 neededBps = uint256(BPS_MAX).sub(_treasuryFeeBps);
        uint256 totalBps;
        for (uint256 i = 0; i < distribution.length; i++) {
            totalBps = totalBps.add(distribution[i].bps);
        }
        require(totalBps == neededBps, Errors.INVALID_DISTRIBUTION_BPS);

        DataTypes.GenericAuctionData memory auctionData =
            DataTypes.GenericAuctionData(
                startPrice,
                currency,
                address(0),
                startTimestamp,
                endTimestamp
            );
        _nftData[nft][nftId].auction = auctionData;
        _nftData[nft][nftId].auctioner = msg.sender;

        for (uint256 i = 0; i < distribution.length; i++) {
            require(distribution[i].recipient != address(0), Errors.ZERO_RECIPIENT);
            _nftData[nft][nftId].distribution.push(distribution[i]);
        }

        IERC721(nft).transferFrom(msg.sender, address(this), nftId);

        emit AuctionCreated(currency, nft, nftId, startTimestamp, endTimestamp, startPrice);
    }

    /**
     * @notice Bids using EIP-2612 permit to approve within the same function call.
     *
     * @param params The BidWithPermitParams struct containing the necessary information.
     */
    function bidWithPermit(DataTypes.BidWithPermitParams memory params) external nonReentrant whenNotPaused {
        IERC20Permit currency = IERC20Permit(_nftData[params.nft][params.nftId].auction.currency);
        currency.permit(
            msg.sender,
            address(this),
            params.amount,
            params.deadline,
            params.v,
            params.r,
            params.s
        );
        _bid(msg.sender, params.onBehalfOf, params.nft, params.nftId, params.amount);
    }

    /**
     * @notice Claims a won NFT after an auction. Can be called by anyone.
     *
     * @param nft The NFT address of the token to claim.
     * @param nftId The NFT ID of the token to claim.
     */
    function claimWonNFT(address nft, uint256 nftId) external nonReentrant whenNotPaused {
        DataTypes.GenericAuctionData storage auction = _nftData[nft][nftId].auction;

        address currency = auction.currency;
        address winner = auction.currentBidder;
        uint256 endTimestamp = auction.endTimestamp;
        uint256 currentBid = auction.currentBid;
        DataTypes.DistributionData[] storage distribution = _nftData[nft][nftId].distribution;

        require(block.timestamp > endTimestamp, Errors.AUCTION_ONGOING);
        require(winner != address(0), Errors.INVALID_BIDDER);

        _distribute(currency, currentBid, distribution);

        delete (_nftData[nft][nftId]);
        IERC721(nft).safeTransferFrom(address(this), winner, nftId);

        emit WonNftClaimed(nft, nftId, winner);
    }

    /**
     * @notice Reclaims an NFT in the unlikely event that an auction did not result in any bids.
     *
     * @param nft The NFT address of the token to reclaim.
     * @param nftId The NFT ID of the token to reclaim.
     */
    function reclaimEndedAuction(address nft, uint256 nftId) external nonReentrant whenNotPaused {
        DataTypes.GenericAuctionData storage auction = _nftData[nft][nftId].auction;
        address currentBidder = auction.currentBidder;
        address auctioner = _nftData[nft][nftId].auctioner;
        uint256 endTimestamp = auction.endTimestamp;

        require(block.timestamp > endTimestamp, Errors.AUCTION_ONGOING);
        require(currentBidder == address(0), Errors.VALID_BIDDER);

        delete (_nftData[nft][nftId]);
        IERC721(nft).safeTransferFrom(address(this), auctioner, nftId);

        emit Reclaimed(nft, nftId);
    }

    /**
     * @dev Admin function to whitelist a currency.
     *
     * @param toWhitelist The currency address to whitelist.
     */
    function whitelist(address toWhitelist) external onlyAdmin {
        _whitelisted[toWhitelist] = true;
    }

    /**
     * @dev Admin function to remove a whitelisted currency.
     *
     * @param toRemove The currency address to remove from the whitelist.
     */
    function removeFromWhitelist(address toRemove) external  onlyAdmin {
        _whitelisted[toRemove] = false;
    }

    /**
     * @dev transfer native Ether, for native Ether recovery in case of stuck Ether
     * due selfdestructs or transfer ether to pre-computated contract address before deployment.
     *
     * @param to recipient of the transfer
     * @param amount amount to send
     */
    function emergencyEtherTransfer(address to, uint256 amount) external onlyAdmin {
        _safeTransferETH(to, amount);
    }

    /**
     * @notice Returns the current configuration of the auction's internal parameters.
     *
     * @return A GenericAuctionConfiguration struct containing the configuration.
     */
    function getConfiguration()
        external
        view
        returns (DataTypes.GenericAuctionConfiguration memory)
    {
        return
            DataTypes.GenericAuctionConfiguration(
                _treasury,
                _minimumAuctionDuration,
                _overtimeWindow,
                _treasuryFeeBps
            );
    }

    /**
     * @notice Returns whether a currency address is whitelisted and allowed to be used in the auction.
     *
     * @param query The address to query.
     */
    function _isWhitelisted(address query) external view returns (bool) {
        return _whitelisted[query];
    }

    /**
     * @notice Returns the auction data for a given NFT.
     *
     * @param nft The NFT address to query.
     * @param nftId The NFT ID to query.
     */
    function getNftData(address nft, uint256 nftId)
        external
        view
        returns (DataTypes.GenericAuctionFullData memory)
    {
        return _nftData[nft][nftId];
    }

    function _bid(
        address spender,
        address onBehalfOf,
        address nft,
        uint256 nftId,
        uint256 amount
    ) internal override {
        require(onBehalfOf != address(0), Errors.INVALID_BIDDER);
        DataTypes.GenericAuctionData storage auction = _nftData[nft][nftId].auction;
        IERC20Permit currency = IERC20Permit(auction.currency);
        uint256 currentBid = auction.currentBid;
        address currentBidder = auction.currentBidder;
        uint40 startTimestamp = auction.startTimestamp;
        uint40 endTimestamp = auction.endTimestamp;

        require(
            block.timestamp > startTimestamp && block.timestamp < endTimestamp,
            Errors.INVALID_BID_TIMESTAMPS
        );
        require(amount > currentBid, Errors.INVALID_BID_AMOUNT);

        if (_overtimeWindow > 0 && block.timestamp > endTimestamp - _overtimeWindow) {
            uint40 newEndTimestamp = endTimestamp + _overtimeWindow;
            auction.endTimestamp = newEndTimestamp;
        }

        auction.currentBidder = onBehalfOf;
        auction.currentBid = amount;

        if (currentBidder != address(0)) {
            if (address(currency) == address(WETH)) {
                WETH.withdraw(currentBid);
                // If Sending ETH fails, re-deposit and send WETH
                (bool success, ) = currentBidder.call{value:currentBid}(new bytes(0));
                if (!success) {
                    WETH.deposit{value:currentBid}();
                    require(WETH.transferFrom(address(this), currentBidder, currentBid));
                }
            } else {
                currency.safeTransfer(currentBidder, currentBid);
            }
        }

        currency.safeTransferFrom(spender, address(this), amount);
        emit BidSubmitted(nft, nftId, onBehalfOf, amount);
    }

    function getRevision() internal pure override returns (uint256) {
        return GENERICAUCTION_REVISION;
    }

    receive() external payable {
        require(msg.sender == address(WETH));
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2 <0.8.0;

import "../../introspection/IERC165.sol";

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

pragma solidity >=0.6.0 <0.8.0;

import "./IERC20.sol";
import "../../math/SafeMath.sol";
import "../../utils/Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using SafeMath for uint256;
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        // solhint-disable-next-line max-line-length
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).add(value);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).sub(value, "SafeERC20: decreased allowance below zero");
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

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
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        uint256 c = a + b;
        if (c < a) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the substraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b > a) return (false, 0);
        return (true, a - b);
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) return (true, 0);
        uint256 c = a * b;
        if (c / a != b) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a / b);
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a % b);
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
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
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: modulo by zero");
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryDiv}.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a % b;
    }
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IERC20Permit is IERC20 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor () internal {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import {SafeMath} from '@openzeppelin/contracts/math/SafeMath.sol';
import {IERC20Permit} from '../interfaces/IERC20Permit.sol';
import {Errors} from '../libraries/Errors.sol';
import {DataTypes} from '../libraries/DataTypes.sol';
import {AdminPausableUpgradeSafe} from './AdminPausableUpgradeSafe.sol';

/**
 * @title AdminPausableAuctionBaseUpgradeSafe
 *
 *
 *
 * @dev A simple implementation that holds basic auction parameter functionality, common to both Aave staking and
 * generic auction types.
 */
abstract contract AuctionBase is AdminPausableUpgradeSafe {
    using SafeERC20 for IERC20Permit;
    using SafeMath for uint256;

    uint16 public constant BPS_MAX = 10000;

    address internal _treasury;
    uint40 internal _minimumAuctionDuration;
    uint40 internal _overtimeWindow;
    uint16 internal _treasuryFeeBps;
    uint8 internal _distributionCap;

    /**
     * @dev Admin function to change the treasury fee BPS.
     *
     * @param newTreasuryFeeBps The new treasury fee to use.
     */
    function setTreasuryFeeBps(uint16 newTreasuryFeeBps) external onlyAdmin {
        require(newTreasuryFeeBps < BPS_MAX, Errors.INVALID_INIT_PARAMS);
        _treasuryFeeBps = newTreasuryFeeBps;
    }

    /**
     * @dev Admin function to change the treasury address.
     *
     * @param newTreasury The new treasury address to use.
     */
    function setTreasuryAddress(address newTreasury) external onlyAdmin {
        require(newTreasury != address(0), Errors.INVALID_INIT_PARAMS);
        _treasury = newTreasury;
    }

    /**
     * @dev Admin function to change the minimum auction duration.
     *
     * @param newMinimumDuration The new minimum auction duration to set.
     */
    function setMinimumAuctionDuration(uint40 newMinimumDuration) external onlyAdmin {
        require(newMinimumDuration > _overtimeWindow, Errors.INVALID_INIT_PARAMS);
        _minimumAuctionDuration = newMinimumDuration;
    }

    /**
     * @dev Admin function to set the auction overtime window.
     *
     * @param newOvertimeWindow The new overtime window to set.
     */
    function setOvertimeWindow(uint40 newOvertimeWindow) external onlyAdmin {
        require(newOvertimeWindow < _minimumAuctionDuration, Errors.INVALID_INIT_PARAMS);
        _overtimeWindow = newOvertimeWindow;
    }

    /**
     * @dev Admin function to change the distribution cap.
     *
     * @param newDistributionCap The new distribution cap to set.
     */
    function setDistributionCap(uint8 newDistributionCap) external onlyAdmin {
        require(newDistributionCap > 0, Errors.INVALID_INIT_PARAMS);
        _distributionCap = newDistributionCap;
    }

    /**
     * @notice Bids on a given NFT with a given amount.
     *
     * @param onBehalfOf The address to bid on behalf of.
     * @param nft The NFT address to bid on.
     * @param nftId The NFT ID to bid on.
     * @param amount The amount to bid with.
     */
    function bid(
        address onBehalfOf,
        address nft,
        uint256 nftId,
        uint256 amount
    ) external whenNotPaused {
        _bid(msg.sender, onBehalfOf, nft, nftId, amount);
    }

    /**
     * @dev Internal function that distributes a given ERC20 token and token amount according to a given
     * distribution array.
     *
     * @param currency The currency address to distribute.
     * @param amount The total amount to distribute.
     * @param distribution The distribution array.
     */
    function _distribute(
        address currency,
        uint256 amount,
        DataTypes.DistributionData[] memory distribution
    ) internal {
        IERC20Permit token = IERC20Permit(currency);
        uint256 leftover = amount;
        uint256 distributionAmount;
        for (uint256 i = 0; i < distribution.length; i++) {
            distributionAmount = amount.mul(distribution[i].bps).div(BPS_MAX);
            leftover = leftover.sub(distributionAmount);
            token.safeTransfer(distribution[i].recipient, distributionAmount);
        }

        // Treasury gets the leftovers, equal to amount.mul(_treasuryFeeBps).div(BPS_MAX) for rounding errors.
        token.safeTransfer(_treasury, leftover);
    }

    function _bid(
        address spender,
        address onBehalfOf,
        address nft,
        uint256 nftId,
        uint256 amount
    ) internal virtual;
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

import {IWETH} from '../interfaces/IWETH.sol';

contract WETHBase {

    IWETH public immutable WETH;

    /**
     * @notice Constructor sets the immutable WETH address.
     */
    constructor(address weth) {
        WETH = IWETH(weth);
    }

    /**
    * @dev transfer ETH to an address, revert if it fails.
    * @param to recipient of the transfer
    * @param value the amount to send
    */
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }    
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

/// Library containing data types needed for the NFT controller & vaults
library DataTypes {

    struct DistributionData {
        address recipient;
        uint256 bps;
    }

    struct StakeAuctionFullData {
        StakeAuctionData auction;
        DistributionData[] distribution;
        address auctioner;
        address vault;
    }

    struct StakeAuctionData {
        uint256 currentBid;
        address currentBidder;
        uint40 startTimestamp;
        uint40 endTimestamp;
    }

    struct GenericAuctionFullData {
        GenericAuctionData auction;
        DistributionData[] distribution;
        address auctioner;
    }

    struct GenericAuctionData {
        uint256 currentBid;
        address currency;
        address currentBidder;
        uint40 startTimestamp;
        uint40 endTimestamp;
    }

    struct StakeAuctionConfiguration {
        address vaultLogic;
        address treasury;
        uint40 minimumAuctionDuration;
        uint40 overtimeWindow;
        uint16 treasuryFeeBps;
        uint16 burnPenaltyBps;
    }

    struct GenericAuctionConfiguration {
        address treasury;
        uint40 minimumAuctionDuration;
        uint40 overtimeWindow;
        uint16 treasuryFeeBps;
    }

    struct BidWithPermitParams {
        uint256 amount;
        uint256 deadline;
        uint256 nftId;
        address onBehalfOf;
        address nft;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
    
    struct RankedAuctionConfiguration {
        uint256 minPrice;
        address recipient;
        address currency;
        uint40 startTimestamp;
        uint40 endTimestamp;
    }

    struct RankedBidData {
        uint256 amount;
        bool outbid;
        bool claimed;
    }

    struct SimpleBidWithPermitParams {
        uint256 amount;
        uint256 deadline;
        address onBehalfOf;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    enum CallType {Call, DelegateCall}
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

// Contains error code strings

library Errors {
  string public constant INVALID_AUCTION_TIMESTAMPS = '1';
  string public constant INVALID_BID_TIMESTAMPS = '2';
  string public constant INVALID_BID_AMOUNT = '3';
  string public constant AUCTION_ONGOING = '4';
  string public constant VALID_BIDDER = '5';
  string public constant NONEXISTANT_VAULT = '6';
  string public constant INVALID_DISTRIBUTION_BPS = '7';
  string public constant AUCTION_EXISTS = '8';
  string public constant NOT_STAKE_AUCTION = '9';
  string public constant INVALID_CALL_TYPE = '10';
  string public constant INVALID_AUCTION_DURATION = '11';
  string public constant INVALID_BIDDER = '12';
  string public constant PAUSED = '13';
  string public constant NOT_ADMIN = '14';
  string public constant INVALID_INIT_PARAMS = '15';
  string public constant INVALID_DISTRIBUTION_COUNT = '16';
  string public constant ZERO_RECIPIENT = '17';
  string public constant ZERO_CURRENCY = '18';
  string public constant RA_NOT_OUTBID = '19';
  string public constant RA_OUTBID = '20';
  string public constant RA_CLAIMED = '21';
  string public constant NO_DISTRIBUTIONS = '22';
  string public constant VAULT_ARRAY_MISMATCH = '23';
  string public constant CURRENCY_NOT_WHITELSITED = '24';
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

/**
 * @title VersionedInit
 *
 * @dev Helper contract to implement initializer functions. To use it, replace
 * the constructor with a function that has the `initializer` modifier.
 * WARNING: Unlike constructors, initializer functions must be manually
 * invoked. This applies both to deploying an Initializable contract, as well
 * as extending an Initializable contract via inheritance.
 * WARNING: When used with inheritance, manual care must be taken to not invoke
 * a parent initializer twice, or ensure that all initializers are idempotent,
 * because this is not dealt with automatically as with constructors.
 *
 *, inspired by the OpenZeppelin Initializable contract
 */
abstract contract VersionedInit {
  /**
   * @dev Indicates that the contract has been initialized.
   */
  uint256 private lastInitializedRevision = 0;

  /**
   * @dev Indicates that the contract is in the process of being initialized.
   */
  bool private initializing;

  /**
   * @dev Modifier to use in the initializer function of a contract.
   */
  modifier initializer() {
    uint256 revision = getRevision();
    require(
      initializing || isConstructor() || revision > lastInitializedRevision,
      'Contract instance has already been initialized'
    );

    bool isTopLevelCall = !initializing;
    if (isTopLevelCall) {
      initializing = true;
      lastInitializedRevision = revision;
    }

    _;

    if (isTopLevelCall) {
      initializing = false;
    }
  }

  /**
   * @dev returns the revision number of the contract
   * Needs to be defined in the inherited class as a constant.
   **/
  function getRevision() internal pure virtual returns (uint256);

  /**
   * @dev Returns true if and only if the function is running in the constructor
   **/
  function isConstructor() private view returns (bool) {
    // extcodesize checks the size of the code stored in an address, and
    // address returns the current address. Since the code is still not
    // deployed when running a constructor, any checks on its code size will
    // yield zero, making it an effective way to detect if a contract is
    // under construction or not.
    uint256 cs;
    //solium-disable-next-line
    assembly {
      cs := extcodesize(address())
    }
    return cs == 0;
  }

  // Reserved storage space to allow for layout changes in the future.
  uint256[50] private ______gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

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

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2 <0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain`call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

import {Errors} from '../libraries/Errors.sol';

/**
 * @title AdminPausableUpgradeSafe
 *
 *
 * 
 * @dev Contract to be inherited from that adds simple administrator pausable functionality. This does not
 * implement any changes on its own as there is no constructor or initializer. Both _admin and _paused must
 * be initialized in the inheriting contract.
 */
contract AdminPausableUpgradeSafe {
    address internal _admin;
    bool internal _paused;
    
    /**
     * @notice Emitted when the contract is paused.
     * 
     * @param admin The current administrator address.
     */
    event Paused(address admin);

    /**
     * @notice Emitted when the contract is unpaused.
     *
     * @param admin The current administrator address.
     */
    event Unpaused(address admin);

    /**
     * @notice Emitted when the admin is set to a different address.
     * 
     * @param to The address of the new administrator. 
     */
    event AdminChanged(address to);

    constructor() {
        _paused = true;
    }

    /**
     * @dev Modifier to only allow functions to be called when not paused.
     */
    modifier whenNotPaused() {
        require(!_paused, Errors.PAUSED);
        _;
    }

    /**
     * @dev Modifier to only allow the admin as the caller.
     */
    modifier onlyAdmin() {
        require(msg.sender == _admin, Errors.NOT_ADMIN);
        _;
    }

    /**
     * @dev Admin function pauses the contract.
     */
    function pause() external onlyAdmin {
        _paused = true;
        emit Paused(_admin);
    }

    /**
     * @dev Admin function unpauses the contract.
     */
    function unpause() external onlyAdmin {
        _paused = false;
        emit Unpaused(_admin);
    }

    /**
     * @dev Admin function that changes the administrator.
     */
    function changeAdmin(address to) external onlyAdmin {
        _admin = to;
        emit AdminChanged(to);
    }

    /**
     * @dev View function that returns the current admin.
     */
    function getAdmin() external view returns (address) {
        return _admin;
    }
}

// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

interface IWETH {
  function deposit() external payable;

  function withdraw(uint256) external;

  function approve(address guy, uint256 wad) external returns (bool);

  function transferFrom(
    address src,
    address dst,
    uint256 wad
  ) external returns (bool);
}

{
  "optimizer": {
    "enabled": true,
    "runs": 200
  },
  "outputSelection": {
    "*": {
      "*": [
        "evm.bytecode",
        "evm.deployedBytecode",
        "abi"
      ]
    }
  },
  "libraries": {}
}