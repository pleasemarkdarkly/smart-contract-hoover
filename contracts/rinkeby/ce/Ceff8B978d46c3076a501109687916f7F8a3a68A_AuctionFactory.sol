//SPDX-License-Identifier: Unlicense
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./IAuctionFactory.sol";
import "./HasSecondarySaleFees.sol";

contract AuctionFactory is IAuctionFactory, ERC721Holder, Ownable {
    using SafeMath for uint256;

    uint256 public totalAuctions;
    uint256 public maxNumberOfSlotsPerAuction;
    uint256 public royaltyFeeMantissa;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => uint256) public auctionsRevenue;
    mapping(address => uint256) public royaltiesReserve;
    bytes4 private constant _INTERFACE_ID_FEES = 0xb7799584;
    address constant GUARD = address(1);

    event LogERC721Deposit(
        address depositor,
        address tokenAddress,
        uint256 tokenId,
        uint256 auctionId,
        uint256 slotIndex,
        uint256 nftSlotIndex,
        uint256 time
    );

    event LogERC721Withdrawal(
        address depositor,
        address tokenAddress,
        uint256 tokenId,
        uint256 auctionId,
        uint256 slotIndex,
        uint256 nftSlotIndex,
        uint256 time
    );

    event LogAuctionCreated(
        uint256 auctionId,
        address auctionOwner,
        uint256 numberOfSlots,
        uint256 startTime,
        uint256 endTime,
        uint256 resetTimer,
        bool supportsWhitelist,
        uint256 time
    );

    event LogBidSubmitted(
        address sender,
        uint256 auctionId,
        uint256 currentBid,
        uint256 totalBid,
        uint256 time
    );

    event LogBidWithdrawal(
        address recipient,
        uint256 auctionId,
        uint256 amount,
        uint256 time
    );

    event LogBidMatched(
        uint256 auctionId,
        uint256 slotIndex,
        uint256 slotReservePrice,
        uint256 winningBidAmount,
        address winner,
        uint256 time
    );

    event LogAuctionExtended(uint256 auctionId, uint256 endTime, uint256 time);

    event LogAuctionCanceled(uint256 auctionId, uint256 time);

    event LogAuctionRevenueWithdrawal(
        address recipient,
        uint256 auctionId,
        uint256 amount,
        uint256 time
    );

    event LogERC721RewardsClaim(
        address claimer,
        uint256 auctionId,
        uint256 slotIndex,
        uint256 time
    );

    event LogRoyaltiesWithdrawal(
        uint256 amount,
        address to,
        address token,
        uint256 time
    );

    modifier onlyExistingAuction(uint256 _auctionId) {
        require(
            _auctionId > 0 && _auctionId <= totalAuctions,
            "Auction doesn't exist"
        );
        _;
    }

    modifier onlyAuctionStarted(uint256 _auctionId) {
        require(
            auctions[_auctionId].startTime < block.timestamp,
            "Auction hasn't started"
        );
        _;
    }

    modifier onlyAuctionNotStarted(uint256 _auctionId) {
        require(
            auctions[_auctionId].startTime > block.timestamp,
            "Auction has started"
        );
        _;
    }

    modifier onlyAuctionNotCanceled(uint256 _auctionId) {
        require(!auctions[_auctionId].isCanceled, "Auction is canceled");
        _;
    }

    modifier onlyAuctionCanceled(uint256 _auctionId) {
        require(auctions[_auctionId].isCanceled, "Auction is not canceled");
        _;
    }

    modifier onlyValidBidAmount(uint256 _bid) {
        require(_bid > 0, "Bid amount must be higher than 0");
        _;
    }

    modifier onlyETH(uint256 _auctionId) {
        require(
            auctions[_auctionId].bidToken == address(0),
            "Token address provided"
        );
        _;
    }

    modifier onlyERC20(uint256 _auctionId) {
        require(
            auctions[_auctionId].bidToken != address(0),
            "No token address provided"
        );
        _;
    }

    modifier onlyIfWhitelistSupported(uint256 _auctionId) {
        require(
            auctions[_auctionId].supportsWhitelist,
            "The auction should support whitelisting"
        );
        _;
    }

    modifier onlyAuctionOwner(uint256 _auctionId) {
        require(
            auctions[_auctionId].auctionOwner == msg.sender,
            "Only auction owner can whitelist addresses"
        );
        _;
    }

    constructor(uint256 _maxNumberOfSlotsPerAuction) {
        require(
            _maxNumberOfSlotsPerAuction > 0 &&
                _maxNumberOfSlotsPerAuction <= 2000,
            "Number of slots cannot be more than 2000"
        );
        maxNumberOfSlotsPerAuction = _maxNumberOfSlotsPerAuction;
    }

    function createAuction(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _resetTimer,
        uint256 _numberOfSlots,
        bool _supportsWhitelist,
        address _bidToken
    ) external override returns (uint256) {
        uint256 currentTime = block.timestamp;

        require(
            currentTime < _startTime,
            "Auction cannot begin before current block timestamp"
        );

        require(
            _startTime < _endTime,
            "Auction cannot end before it has launched"
        );

        require(_resetTimer > 0, "Reset timer must be higher than 0 seconds");

        require(
            _numberOfSlots > 0 && _numberOfSlots <= maxNumberOfSlotsPerAuction,
            "Auction can have between 1 and 2000 slots"
        );

        uint256 _auctionId = totalAuctions.add(1);

        auctions[_auctionId].auctionOwner = msg.sender;
        auctions[_auctionId].startTime = _startTime;
        auctions[_auctionId].endTime = _endTime;
        auctions[_auctionId].resetTimer = _resetTimer;
        auctions[_auctionId].numberOfSlots = _numberOfSlots;
        auctions[_auctionId].supportsWhitelist = _supportsWhitelist;
        auctions[_auctionId].bidToken = _bidToken;
        auctions[_auctionId].nextBidders[GUARD] = GUARD;

        totalAuctions = _auctionId;

        emit LogAuctionCreated(
            _auctionId,
            msg.sender,
            _numberOfSlots,
            _startTime,
            _endTime,
            _resetTimer,
            _supportsWhitelist,
            block.timestamp
        );

        return _auctionId;
    }

    function depositERC721(
        uint256 _auctionId,
        uint256 _slotIndex,
        uint256 _tokenId,
        address _tokenAddress
    )
        public
        override
        onlyExistingAuction(_auctionId)
        onlyAuctionNotStarted(_auctionId)
        onlyAuctionNotCanceled(_auctionId)
        returns (uint256)
    {
        address _depositor = msg.sender;

        require(
            _tokenAddress != address(0),
            "Zero address was provided for token"
        );

        require(
            !auctions[_auctionId].supportsWhitelist ||
                auctions[_auctionId].whitelistAddresses[_depositor],
            "You are not allowed to deposit"
        );

        require(
            auctions[_auctionId].numberOfSlots >= _slotIndex && _slotIndex > 0,
            "You are trying to deposit into a non-existing slot"
        );

        require(
            auctions[_auctionId].slots[_slotIndex].totalDepositedNfts < 40,
            "Cannot have more than 40 NFTs in slot"
        );

        DepositedERC721 memory item =
            DepositedERC721({
                tokenId: _tokenId,
                tokenAddress: _tokenAddress,
                depositor: _depositor
            });

        uint256 _nftSlotIndex =
            auctions[_auctionId].slots[_slotIndex].totalDepositedNfts.add(1);

        auctions[_auctionId].slots[_slotIndex].depositedNfts[
            _nftSlotIndex
        ] = item;

        auctions[_auctionId].slots[_slotIndex]
            .totalDepositedNfts = _nftSlotIndex;

        IERC721(_tokenAddress).safeTransferFrom(
            _depositor,
            address(this),
            _tokenId
        );

        auctions[_auctionId].totalDepositedERC721s = auctions[_auctionId]
            .totalDepositedERC721s
            .add(1);

        emit LogERC721Deposit(
            _depositor,
            _tokenAddress,
            _tokenId,
            _auctionId,
            _slotIndex,
            _nftSlotIndex,
            block.timestamp
        );

        return _nftSlotIndex;
    }

    function depositMultipleERC721(
        uint256 _auctionId,
        uint256 _slotIndex,
        ERC721[] calldata _tokens
    )
        public
        override
        onlyExistingAuction(_auctionId)
        onlyAuctionNotStarted(_auctionId)
        onlyAuctionNotCanceled(_auctionId)
        returns (uint256[] memory)
    {
        address _depositor = msg.sender;
        uint256[] memory _nftSlotIndexes = new uint256[](_tokens.length);

        require(
            !auctions[_auctionId].supportsWhitelist ||
                auctions[_auctionId].whitelistAddresses[_depositor],
            "You are not allowed to deposit"
        );

        require(
            auctions[_auctionId].numberOfSlots >= _slotIndex && _slotIndex > 0,
            "You are trying to deposit into a non-existing slot"
        );

        require(
            ((auctions[_auctionId].slots[_slotIndex].totalDepositedNfts +
                _tokens.length) <= 40),
            "Cannot have more than 40 NFTs in slot"
        );

        for (uint256 i = 0; i < _tokens.length; i++) {
            _nftSlotIndexes[i] = depositERC721(
                _auctionId,
                _slotIndex,
                _tokens[i].tokenId,
                _tokens[i].tokenAddress
            );
        }

        return _nftSlotIndexes;
    }

    function batchDepositToAuction(
        uint256 _auctionId,
        uint256[] calldata _slotIndices,
        ERC721[][] calldata _tokens
    )
        external
        override
        onlyExistingAuction(_auctionId)
        onlyAuctionNotStarted(_auctionId)
        onlyAuctionNotCanceled(_auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[_auctionId];

        require(
            _slotIndices.length <= auction.numberOfSlots,
            "Exceeding auction slots"
        );
        require(_slotIndices.length <= 10, "Slots should be no more than 10");
        require(
            _slotIndices.length == _tokens.length,
            "Slots number should be equal to the ERC721 batches"
        );

        for (uint256 i = 0; i < _slotIndices.length; i++) {
            require(
                _tokens[i].length <= 5,
                "Max 5 ERC721s could be transferred"
            );
            depositMultipleERC721(_auctionId, _slotIndices[i], _tokens[i]);
        }

        return true;
    }

    function ethBid(uint256 auctionId)
        public
        payable
        override
        onlyExistingAuction(auctionId)
        onlyAuctionStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        onlyETH(auctionId)
        onlyValidBidAmount(msg.value)
    {
        Auction storage auction = auctions[auctionId];

        require(block.timestamp < auction.endTime, "Auction has ended");
        require(
            auction.totalDepositedERC721s > 0,
            "No deposited NFTs in auction"
        );

        uint256 bidderCurrentBalance = auction.bidBalance[msg.sender];

        // Check if this is first time bidding
        if (bidderCurrentBalance == 0) {
            // Add bid without checks if total bids are less than total slots
            if (auction.numberOfBids < auction.numberOfSlots) {
                addBid(auctionId, msg.sender, msg.value);
                // Check if slots are filled (we have more bids than slots)
            } else if (auction.numberOfBids >= auction.numberOfSlots) {
                // If slots are filled, check if the bid is within the winning slots
                require(
                    isWinningBid(auctionId, msg.value),
                    "Bid should be winnning"
                );
                // Add bid only if it is within the winning slots
                addBid(auctionId, msg.sender, msg.value);
                if (auction.endTime.sub(block.timestamp) < auction.resetTimer) {
                    // Extend the auction if the remaining time is less than the reset timer
                    extendAuction(auctionId);
                }
            }
            // Check if the user has previously submitted bids
        } else if (bidderCurrentBalance > 0) {
            // Find which is the next highest bidder balance and ensure the incremented bid is bigger
            address previousBidder = _findPreviousBidder(auctionId, msg.sender);
            require(
                msg.value > auction.bidBalance[previousBidder],
                "New bid should be higher than next highest slot bid"
            );
            // Update bid directly without additional checks if total bids are less than total slots
            if (auction.numberOfBids < auction.numberOfSlots) {
                updateBid(
                    auctionId,
                    msg.sender,
                    bidderCurrentBalance.add(msg.value)
                );
                // If slots are filled, check if the current bidder balance + the new amount will be withing the winning slots
            } else if (auction.numberOfBids >= auction.numberOfSlots) {
                require(
                    isWinningBid(
                        auctionId,
                        bidderCurrentBalance.add(msg.value)
                    ),
                    "Bid should be winnning"
                );
                // Update the bid if the new incremented balance falls within the winning slots
                updateBid(
                    auctionId,
                    msg.sender,
                    bidderCurrentBalance.add(msg.value)
                );
                if (auction.endTime.sub(block.timestamp) < auction.resetTimer) {
                    // Extend the auction if the remaining time is less than the reset timer
                    extendAuction(auctionId);
                }
            }
        }
    }

    function erc20Bid(uint256 auctionId, uint256 amount)
        external
        override
        onlyExistingAuction(auctionId)
        onlyAuctionStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        onlyERC20(auctionId)
        onlyValidBidAmount(amount)
    {
        Auction storage auction = auctions[auctionId];

        require(block.timestamp < auction.endTime, "Auction has ended");
        require(
            auction.totalDepositedERC721s > 0,
            "No deposited NFTs in auction"
        );

        IERC20 bidToken = IERC20(auction.bidToken);
        uint256 allowance = bidToken.allowance(msg.sender, address(this));

        require(allowance >= amount, "Token allowance too small");

        uint256 bidderCurrentBalance = auction.bidBalance[msg.sender];

        // Check if this is first time bidding
        if (bidderCurrentBalance == 0) {
            // Add bid without checks if total bids are less than total slots
            if (auction.numberOfBids < auction.numberOfSlots) {
                addBid(auctionId, msg.sender, amount);
                bidToken.transferFrom(msg.sender, address(this), amount);
                // Check if slots are filled (if we have more bids than slots)
            } else if (auction.numberOfBids >= auction.numberOfSlots) {
                // If slots are filled, check if the bid is within the winning slots
                require(
                    isWinningBid(auctionId, amount),
                    "Bid should be winnning"
                );
                // Add bid only if it is within the winning slots
                addBid(auctionId, msg.sender, amount);
                bidToken.transferFrom(msg.sender, address(this), amount);
                if (auction.endTime.sub(block.timestamp) < auction.resetTimer) {
                    // Extend the auction if the remaining time is less than the reset timer
                    extendAuction(auctionId);
                }
            }
            // Check if the user has previously submitted bids
        } else if (bidderCurrentBalance > 0) {
            // Find which is the next highest bidder balance and ensure the incremented bid is bigger
            address previousBidder = _findPreviousBidder(auctionId, msg.sender);
            require(
                amount > auction.bidBalance[previousBidder],
                "New bid should be higher than next highest slot bid"
            );
            // Update bid directly without additional checks if total bids are less than total slots
            if (auction.numberOfBids < auction.numberOfSlots) {
                updateBid(
                    auctionId,
                    msg.sender,
                    bidderCurrentBalance.add(amount)
                );
                bidToken.transferFrom(msg.sender, address(this), amount);
                // If slots are filled, check if the current bidder balance + the new amount will be withing the winning slots
            } else if (auction.numberOfBids >= auction.numberOfSlots) {
                require(
                    isWinningBid(auctionId, bidderCurrentBalance.add(amount)),
                    "Bid should be winnning"
                );
                // Update the bid if the new incremented balance falls within the winning slots
                updateBid(
                    auctionId,
                    msg.sender,
                    bidderCurrentBalance.add(amount)
                );
                bidToken.transferFrom(msg.sender, address(this), amount);
                if (auction.endTime.sub(block.timestamp) < auction.resetTimer) {
                    // Extend the auction if the remaining time is less than the reset timer
                    extendAuction(auctionId);
                }
            }
        }
    }

    function finalizeAuction(uint256 auctionId)
        external
        override
        onlyExistingAuction(auctionId)
        onlyAuctionNotCanceled(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];

        require(
            block.timestamp > auction.endTime && !auction.isFinalized,
            "Auction has not finished"
        );

        address[] memory bidders;
        uint256 lastAwardedIndex = 0;

        // Get top bidders for the auction, according to the number of slots
        if (auction.numberOfBids > auction.numberOfSlots) {
            bidders = getTopBidders(auctionId, auction.numberOfSlots);
        } else {
            bidders = getTopBidders(auctionId, auction.numberOfBids);
        }

        // Award the slots by checking the highest bidders and minimum reserve values
        for (uint256 i = 0; i < bidders.length; i++) {
            for (
                lastAwardedIndex;
                lastAwardedIndex < auction.numberOfSlots;
                lastAwardedIndex++
            ) {
                if (
                    auction.bidBalance[bidders[i]] >=
                    auction.slots[lastAwardedIndex + 1].reservePrice
                ) {
                    auction.slots[lastAwardedIndex + 1]
                        .reservePriceReached = true;
                    auction.slots[lastAwardedIndex + 1]
                        .winningBidAmount = auction.bidBalance[bidders[i]];
                    auction.slots[lastAwardedIndex + 1].winner = bidders[i];

                    emit LogBidMatched(
                        auctionId,
                        lastAwardedIndex + 1,
                        auction.slots[lastAwardedIndex + 1].reservePrice,
                        auction.slots[lastAwardedIndex + 1].winningBidAmount,
                        auction.slots[lastAwardedIndex + 1].winner,
                        block.timestamp
                    );

                    lastAwardedIndex++;

                    break;
                }
            }
        }

        // Calculate the auction revenue from sold slots and reset bid balances
        for (uint256 i = 0; i < auction.numberOfSlots; i++) {
            if (auction.slots[i + 1].reservePriceReached) {
                auction.winners[i + 1] = auction.slots[i + 1].winner;
                auctionsRevenue[auctionId] = auctionsRevenue[auctionId].add(
                    auction.bidBalance[auction.slots[i + 1].winner]
                );
                auction.bidBalance[auction.slots[i + 1].winner] = 0;
            }
        }

        // Calculate DAO fee and deduct from auction revenue
        uint256 _royaltyFee =
            calculateRoyaltyFee(auctionsRevenue[auctionId], royaltyFeeMantissa);
        auctionsRevenue[auctionId] = auctionsRevenue[auctionId].sub(
            _royaltyFee
        );
        royaltiesReserve[auction.bidToken] = royaltiesReserve[auction.bidToken]
            .add(_royaltyFee);
        auction.isFinalized = true;

        return true;
    }

    function withdrawERC20Bid(uint256 auctionId)
        external
        override
        onlyExistingAuction(auctionId)
        onlyAuctionStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        onlyERC20(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];
        address sender = msg.sender;
        uint256 amount = auction.bidBalance[sender];

        require(amount > 0, "You have 0 deposited");
        require(
            auction.numberOfBids > auction.numberOfSlots,
            "Cannot withdraw winning bid!"
        );
        require(
            !isWinningBid(auctionId, amount),
            "Cannot withdraw winning bid!"
        );

        removeBid(auctionId, sender);
        IERC20 bidToken = IERC20(auction.bidToken);
        bidToken.transfer(sender, amount);

        emit LogBidWithdrawal(sender, auctionId, amount, block.timestamp);

        return true;
    }

    function withdrawEthBid(uint256 auctionId)
        external
        override
        onlyExistingAuction(auctionId)
        onlyAuctionStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        onlyETH(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];
        address payable recipient = msg.sender;
        uint256 amount = auction.bidBalance[recipient];

        require(amount > 0, "You have 0 deposited");
        require(
            auction.numberOfBids > auction.numberOfSlots,
            "Cannot withdraw winning bid!"
        );
        require(
            !isWinningBid(auctionId, amount),
            "Cannot withdraw winning bid!"
        );

        removeBid(auctionId, recipient);
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed.");

        emit LogBidWithdrawal(recipient, auctionId, amount, block.timestamp);

        return true;
    }

    function withdrawDepositedERC721(
        uint256 auctionId,
        uint256 slotIndex,
        uint256 nftSlotIndex
    )
        public
        override
        onlyExistingAuction(auctionId)
        onlyAuctionCanceled(auctionId)
        returns (bool)
    {
        DepositedERC721 memory nftForWithdrawal =
            auctions[auctionId].slots[slotIndex].depositedNfts[nftSlotIndex];

        require(
            msg.sender == nftForWithdrawal.depositor,
            "Only depositor can withdraw"
        );

        delete auctions[auctionId].slots[slotIndex].depositedNfts[nftSlotIndex];

        IERC721(nftForWithdrawal.tokenAddress).safeTransferFrom(
            address(this),
            nftForWithdrawal.depositor,
            nftForWithdrawal.tokenId
        );

        emit LogERC721Withdrawal(
            msg.sender,
            nftForWithdrawal.tokenAddress,
            nftForWithdrawal.tokenId,
            auctionId,
            slotIndex,
            nftSlotIndex,
            block.timestamp
        );

        return true;
    }

    function withdrawMultipleERC721FromNonWinningSlot(
        uint256 auctionId,
        uint256 slotIndex
    )
        external
        override
        onlyExistingAuction(auctionId)
        onlyAuctionStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];
        Slot storage nonWinningSlot = auction.slots[slotIndex];

        require(
            !auction.slots[slotIndex].reservePriceReached,
            "Can withdraw only if reserve price is not met"
        );

        require(auction.isFinalized, "Auction should be finalized");

        for (uint256 i = 0; i < nonWinningSlot.totalDepositedNfts; i++) {
            withdrawERC721FromNonWinningSlot(auctionId, slotIndex, (i + 1));
        }

        return true;
    }

    function withdrawERC721FromNonWinningSlot(
        uint256 auctionId,
        uint256 slotIndex,
        uint256 nftSlotIndex
    )
        public
        override
        onlyExistingAuction(auctionId)
        onlyAuctionStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        returns (bool)
    {
        DepositedERC721 memory nftForWithdrawal =
            auctions[auctionId].slots[slotIndex].depositedNfts[nftSlotIndex];

        require(
            msg.sender == nftForWithdrawal.depositor,
            "Only depositor can withdraw"
        );

        require(
            !auctions[auctionId].slots[slotIndex].reservePriceReached,
            "Can withdraw only if reserve price is not met"
        );

        require(auctions[auctionId].isFinalized, "Auction should be finalized");

        IERC721(nftForWithdrawal.tokenAddress).safeTransferFrom(
            address(this),
            nftForWithdrawal.depositor,
            nftForWithdrawal.tokenId
        );

        emit LogERC721Withdrawal(
            msg.sender,
            nftForWithdrawal.tokenAddress,
            nftForWithdrawal.tokenId,
            auctionId,
            slotIndex,
            nftSlotIndex,
            block.timestamp
        );

        return true;
    }

    function cancelAuction(uint256 _auctionId)
        external
        override
        onlyExistingAuction(_auctionId)
        onlyAuctionNotStarted(_auctionId)
        onlyAuctionNotCanceled(_auctionId)
        onlyAuctionOwner(_auctionId)
        returns (bool)
    {
        auctions[_auctionId].isCanceled = true;

        emit LogAuctionCanceled(_auctionId, block.timestamp);

        return true;
    }

    function whitelistMultipleAddresses(
        uint256 auctionId,
        address[] calldata addressesToWhitelist
    )
        external
        override
        onlyExistingAuction(auctionId)
        onlyIfWhitelistSupported(auctionId)
        onlyAuctionOwner(auctionId)
        onlyAuctionNotStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];

        for (uint256 i = 0; i < addressesToWhitelist.length; i++) {
            auction.whitelistAddresses[addressesToWhitelist[i]] = true;
        }

        return true;
    }

    function getDepositedNftsInSlot(uint256 auctionId, uint256 slotIndex)
        external
        view
        override
        onlyExistingAuction(auctionId)
        returns (DepositedERC721[] memory)
    {
        uint256 nftsInSlot =
            auctions[auctionId].slots[slotIndex].totalDepositedNfts;

        DepositedERC721[] memory nfts = new DepositedERC721[](nftsInSlot);

        for (uint256 i = 0; i < nftsInSlot; i++) {
            nfts[i] = auctions[auctionId].slots[slotIndex].depositedNfts[i + 1];
        }
        return nfts;
    }

    function getTotalDepositedNftsInSlot(uint256 auctionId, uint256 slotIndex)
        external
        view
        override
        onlyExistingAuction(auctionId)
        returns (uint256)
    {
        return auctions[auctionId].slots[slotIndex].totalDepositedNfts;
    }

    function getSlotWinner(uint256 auctionId, uint256 slotIndex)
        external
        view
        override
        returns (address)
    {
        return auctions[auctionId].winners[slotIndex];
    }

    function getBidderBalance(uint256 auctionId, address bidder)
        external
        view
        override
        onlyExistingAuction(auctionId)
        returns (uint256)
    {
        return auctions[auctionId].bidBalance[bidder];
    }

    function isAddressWhitelisted(uint256 auctionId, address addressToCheck)
        external
        view
        override
        onlyExistingAuction(auctionId)
        returns (bool)
    {
        return auctions[auctionId].whitelistAddresses[addressToCheck];
    }

    function extendAuction(uint256 auctionId)
        internal
        onlyExistingAuction(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];

        require(
            block.timestamp < auction.endTime,
            "Cannot extend the auction if it has already ended"
        );

        uint256 resetTimer = auction.resetTimer;
        auction.endTime = auction.endTime.add(resetTimer);

        emit LogAuctionExtended(auctionId, auction.endTime, block.timestamp);

        return true;
    }

    function withdrawAuctionRevenue(uint256 auctionId)
        external
        override
        onlyExistingAuction(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];
        require(auction.isFinalized, "Auction should have ended");

        uint256 amountToWithdraw = auctionsRevenue[auctionId];

        auctionsRevenue[auctionId] = 0;

        if (auction.bidToken == address(0)) {
            (bool success, ) =
                payable(auction.auctionOwner).call{value: amountToWithdraw}("");
            require(success, "Transfer failed.");
        }

        if (auction.bidToken != address(0)) {
            IERC20 bidToken = IERC20(auction.bidToken);
            bidToken.transfer(auction.auctionOwner, amountToWithdraw);
        }

        emit LogAuctionRevenueWithdrawal(
            auction.auctionOwner,
            auctionId,
            amountToWithdraw,
            block.timestamp
        );

        return true;
    }

    function claimERC721Rewards(uint256 auctionId, uint256 slotIndex)
        external
        override
        returns (bool)
    {
        address claimer = msg.sender;

        Auction storage auction = auctions[auctionId];
        Slot storage winningSlot = auction.slots[slotIndex];

        require(auction.isFinalized, "Auction should have ended");
        require(
            auction.winners[slotIndex] == claimer,
            "Only the winner can claim rewards"
        );
        require(
            winningSlot.reservePriceReached,
            "The reserve price hasn't been met"
        );

        for (uint256 i = 0; i < winningSlot.totalDepositedNfts; i++) {
            DepositedERC721 memory nftForWithdrawal =
                winningSlot.depositedNfts[i + 1];

            if (nftForWithdrawal.tokenId != 0) {
                IERC721(nftForWithdrawal.tokenAddress).safeTransferFrom(
                    address(this),
                    claimer,
                    nftForWithdrawal.tokenId
                );
            }
        }

        emit LogERC721RewardsClaim(
            claimer,
            auctionId,
            slotIndex,
            block.timestamp
        );

        return true;
    }

    function setRoyaltyFeeMantissa(uint256 _royaltyFeeMantissa)
        external
        override
        onlyOwner
        returns (uint256)
    {
        require(_royaltyFeeMantissa < 1e17, "Should be less than 10%");
        royaltyFeeMantissa = _royaltyFeeMantissa;

        return royaltyFeeMantissa;
    }

    function calculateRoyaltyFee(uint256 amount, uint256 _royaltyFeeMantissa)
        internal
        pure
        returns (uint256)
    {
        uint256 result = _royaltyFeeMantissa.mul(amount);
        result = result.div(1e18);
        return result;
    }

    function calculateAndDistributeSecondarySaleFees(
        uint256 _auctionId,
        uint256 _slotIndex
    ) internal returns (uint256) {
        Auction storage auction = auctions[_auctionId];
        Slot storage slot = auction.slots[_slotIndex];

        require(slot.totalDepositedNfts > 0, "No NFTs deposited");
        require(slot.winningBidAmount > 0, "Winning bid should be more than 0");

        uint256 averageERC721SalePrice =
            slot.winningBidAmount.div(slot.totalDepositedNfts);

        uint256 totalFeesPaidForSlot = 0;

        for (uint256 i = 0; i < slot.totalDepositedNfts; i++) {
            DepositedERC721 memory nft = slot.depositedNfts[i + 1];

            if (
                nft.tokenAddress != address(0) &&
                IERC721(nft.tokenAddress).supportsInterface(_INTERFACE_ID_FEES)
            ) {
                HasSecondarySaleFees withFees =
                    HasSecondarySaleFees(nft.tokenAddress);
                address payable[] memory recipients =
                    withFees.getFeeRecipients(nft.tokenId);
                uint256[] memory fees = withFees.getFeeBps(nft.tokenId);
                require(
                    fees.length == recipients.length,
                    "Splits number should be equal"
                );
                uint256 value = averageERC721SalePrice;
                for (uint256 j = 0; j < fees.length; j++) {
                    Fee memory interimFee =
                        subFee(
                            value,
                            averageERC721SalePrice.mul(fees[j]).div(10000)
                        );
                    value = interimFee.remainingValue;

                    if (
                        auction.bidToken == address(0) &&
                        interimFee.feeValue > 0
                    ) {
                        (bool success, ) =
                            recipients[j].call{value: interimFee.feeValue}("");
                        require(success, "Transfer failed.");
                    }

                    if (
                        auction.bidToken != address(0) &&
                        interimFee.feeValue > 0
                    ) {
                        IERC20 token = IERC20(auction.bidToken);
                        token.transfer(
                            address(recipients[j]),
                            interimFee.feeValue
                        );
                    }

                    totalFeesPaidForSlot = totalFeesPaidForSlot.add(
                        interimFee.feeValue
                    );
                }
            }
        }

        return totalFeesPaidForSlot;
    }

    function subFee(uint256 value, uint256 fee)
        internal
        pure
        returns (Fee memory interimFee)
    {
        if (value > fee) {
            interimFee.remainingValue = value - fee;
            interimFee.feeValue = fee;
        } else {
            interimFee.remainingValue = 0;
            interimFee.feeValue = value;
        }
    }

    function withdrawRoyalties(address _token, address _to)
        external
        override
        onlyOwner
        returns (uint256)
    {
        uint256 amountToWithdraw = royaltiesReserve[_token];
        require(amountToWithdraw > 0, "Amount is 0");

        royaltiesReserve[_token] = 0;

        if (_token == address(0)) {
            (bool success, ) = payable(_to).call{value: amountToWithdraw}("");
            require(success, "Transfer failed.");
        }

        if (_token != address(0)) {
            IERC20 token = IERC20(_token);
            token.transfer(_to, amountToWithdraw);
        }

        emit LogRoyaltiesWithdrawal(
            amountToWithdraw,
            _to,
            _token,
            block.timestamp
        );

        return amountToWithdraw;
    }

    function setMinimumReserveForAuctionSlots(
        uint256 auctionId,
        uint256[] calldata minimumReserveValues
    )
        external
        override
        onlyExistingAuction(auctionId)
        onlyAuctionNotStarted(auctionId)
        onlyAuctionNotCanceled(auctionId)
        returns (bool)
    {
        Auction storage auction = auctions[auctionId];

        require(
            auction.numberOfSlots == minimumReserveValues.length,
            "Incorrect number of slots"
        );

        for (uint256 i = 0; i < minimumReserveValues.length; i++) {
            auction.slots[i + 1].reservePrice = minimumReserveValues[i];
        }

        return true;
    }

    function getMinimumReservePriceForSlot(uint256 auctionId, uint256 slotIndex)
        external
        view
        override
        returns (uint256)
    {
        return auctions[auctionId].slots[slotIndex].reservePrice;
    }

    function addBid(
        uint256 auctionId,
        address bidder,
        uint256 bid
    ) internal {
        require(auctions[auctionId].nextBidders[bidder] == address(0));
        address index = _findIndex(auctionId, bid);
        auctions[auctionId].bidBalance[bidder] = bid;
        auctions[auctionId].nextBidders[bidder] = auctions[auctionId]
            .nextBidders[index];
        auctions[auctionId].nextBidders[index] = bidder;
        auctions[auctionId].numberOfBids++;

        emit LogBidSubmitted(
            bidder,
            auctionId,
            bid,
            auctions[auctionId].bidBalance[bidder],
            block.timestamp
        );
    }

    function removeBid(uint256 auctionId, address bidder) internal {
        require(auctions[auctionId].nextBidders[bidder] != address(0));
        address previousBidder = _findPreviousBidder(auctionId, bidder);
        auctions[auctionId].nextBidders[previousBidder] = auctions[auctionId]
            .nextBidders[bidder];
        auctions[auctionId].nextBidders[bidder] = address(0);
        auctions[auctionId].bidBalance[bidder] = 0;
        auctions[auctionId].numberOfBids--;
    }

    function updateBid(
        uint256 auctionId,
        address bidder,
        uint256 newValue
    ) internal {
        require(auctions[auctionId].nextBidders[bidder] != address(0));
        address previousBidder = _findPreviousBidder(auctionId, bidder);
        address nextBidder = auctions[auctionId].nextBidders[bidder];
        if (_verifyIndex(auctionId, previousBidder, newValue, nextBidder)) {
            auctions[auctionId].bidBalance[bidder] = newValue;
        } else {
            removeBid(auctionId, bidder);
            addBid(auctionId, bidder, newValue);
        }
    }

    function getTopBidders(uint256 auctionId, uint256 n)
        public
        view
        returns (address[] memory)
    {
        require(n <= auctions[auctionId].numberOfBids);
        address[] memory biddersList = new address[](n);
        address currentAddress = auctions[auctionId].nextBidders[GUARD];
        for (uint256 i = 0; i < n; ++i) {
            biddersList[i] = currentAddress;
            currentAddress = auctions[auctionId].nextBidders[currentAddress];
        }

        return biddersList;
    }

    function isWinningBid(uint256 auctionId, uint256 bid)
        public
        view
        returns (bool)
    {
        address[] memory bidders =
            getTopBidders(auctionId, auctions[auctionId].numberOfSlots);
        uint256 lowestEligibleBid =
            auctions[auctionId].bidBalance[bidders[bidders.length - 1]];
        if (bid > lowestEligibleBid) {
            return true;
        } else {
            return false;
        }
    }

    function _verifyIndex(
        uint256 auctionId,
        address previousBidder,
        uint256 newValue,
        address nextBidder
    ) internal view returns (bool) {
        return
            (previousBidder == GUARD ||
                auctions[auctionId].bidBalance[previousBidder] >= newValue) &&
            (nextBidder == GUARD ||
                newValue > auctions[auctionId].bidBalance[nextBidder]);
    }

    function _findIndex(uint256 auctionId, uint256 newValue)
        internal
        view
        returns (address)
    {
        address addressToInsertAfter = GUARD;
        while (true) {
            if (
                _verifyIndex(
                    auctionId,
                    addressToInsertAfter,
                    newValue,
                    auctions[auctionId].nextBidders[addressToInsertAfter]
                )
            ) return addressToInsertAfter;
            addressToInsertAfter = auctions[auctionId].nextBidders[
                addressToInsertAfter
            ];
        }
    }

    function _isPreviousBidder(
        uint256 auctionId,
        address bidder,
        address previousBidder
    ) internal view returns (bool) {
        return auctions[auctionId].nextBidders[previousBidder] == bidder;
    }

    function _findPreviousBidder(uint256 auctionId, address bidder)
        internal
        view
        returns (address)
    {
        address currentAddress = GUARD;
        while (auctions[auctionId].nextBidders[currentAddress] != GUARD) {
            if (_isPreviousBidder(auctionId, bidder, currentAddress))
                return currentAddress;
            currentAddress = auctions[auctionId].nextBidders[currentAddress];
        }
        return address(0);
    }

    receive() external payable {
        uint256 latestAuctionId = totalAuctions;
        ethBid(latestAuctionId);
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

pragma solidity >=0.6.0 <0.8.0;

import "./IERC721Receiver.sol";

  /**
   * @dev Implementation of the {IERC721Receiver} interface.
   *
   * Accepts all token transfers. 
   * Make sure the contract is able to use its token with {IERC721-safeTransferFrom}, {IERC721-approve} or {IERC721-setApprovalForAll}.
   */
contract ERC721Holder is IERC721Receiver {

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     *
     * Always returns `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

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
    constructor () internal {
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

//SPDX-License-Identifier: Unlicense
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

/// @title Users bid to this contract in order to win a slot with deposited ERC721 tokens.
/// @notice This interface should be implemented by the Auction contract
/// @dev This interface should be implemented by the Auction contract
interface IAuctionFactory {
    struct Auction {
        address auctionOwner;
        uint256 startTime;
        uint256 endTime;
        uint256 resetTimer;
        uint256 numberOfSlots;
        uint256 numberOfBids;
        bool supportsWhitelist;
        bool isCanceled;
        address bidToken;
        bool isFinalized;
        uint256 totalDepositedERC721s;
        mapping(uint256 => Slot) slots;
        mapping(address => bool) whitelistAddresses;
        mapping(address => uint256) bidBalance;
        mapping(address => address) nextBidders;
        mapping(uint256 => address) winners;
    }

    struct Slot {
        uint256 totalDepositedNfts;
        uint256 reservePrice;
        uint256 winningBidAmount;
        bool reservePriceReached;
        address winner;
        mapping(uint256 => DepositedERC721) depositedNfts;
    }

    struct ERC721 {
        uint256 tokenId;
        address tokenAddress;
    }

    struct DepositedERC721 {
        address tokenAddress;
        uint256 tokenId;
        address depositor;
    }

    struct Fee {
        uint remainingValue;
        uint feeValue;
    }

    /// @notice Create an auction with initial parameters
    /// @param _startTime The start of the auction
    /// @param _endTime End of the auction
    /// @param _resetTimer Reset timer in seconds
    /// @param _numberOfSlots The number of slots which the auction will have
    /// @param _supportsWhitelist Array of addresses allowed to deposit
    /// @param _bidToken Address of the token used for bidding - can be address(0)
    function createAuction(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _resetTimer,
        uint256 _numberOfSlots,
        bool _supportsWhitelist,
        address _bidToken
    ) external returns (uint256);

    /// @notice Deposit ERC721 assets to the specified Auction
    /// @param auctionId The auction id
    /// @param slotIndex Index of the slot
    /// @param tokenId Id of the ERC721 token
    /// @param tokenAddress Address of the ERC721 contract
    function depositERC721(
        uint256 auctionId,
        uint256 slotIndex,
        uint256 tokenId,
        address tokenAddress
    ) external returns (uint256);

    /// @notice Deposit ERC721 assets to the specified Auction
    /// @param auctionId The auction id
    /// @param slotIndex Index of the slot
    /// @param tokens Array of ERC721 objects
    function depositMultipleERC721(
        uint256 auctionId,
        uint256 slotIndex,
        ERC721[] calldata tokens
    ) external returns (uint256[] memory);

    /// @notice Deposit ERC721 assets to the specified Auction
    /// @param auctionId The auction id
    /// @param slotIndices Array of slot indexes
    /// @param tokens Array of ERC721 arrays
    function batchDepositToAuction(
        uint256 auctionId,
        uint256[] calldata slotIndices,
        ERC721[][] calldata tokens
    )external returns (bool);

    /// @notice Sends a bid (ETH) to the specified auciton
    /// @param auctionId The auction id
    function ethBid(uint256 auctionId) external payable;

    /// @notice Sends a bid (ERC20) to the specified auciton
    /// @param auctionId The auction id
    function erc20Bid(uint256 auctionId, uint256 amount) external;

    /// @notice Distributes all slot assets to the bidders and winning bids to the collector
    /// @param auctionId The auction id
    function finalizeAuction(uint256 auctionId)
        external
        returns (bool);

    /// @notice Withdraws the bid amount after auction is finialized and bid is non winning
    /// @param auctionId The auction id
    function withdrawERC20Bid(uint256 auctionId) external returns (bool);

    /// @notice Withdraws the eth bid amount after auction is finalized and bid is non winning
    /// @param auctionId The auction id
    function withdrawEthBid(uint256 auctionId) external returns (bool);

    /// @notice Withdraws the deposited ERC721 before an auction has started
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    /// @param nftSlotIndex The index of the NFT inside the particular slot - it is returned on depositERC721() call
    function withdrawDepositedERC721(
        uint256 auctionId,
        uint256 slotIndex,
        uint256 nftSlotIndex
    ) external returns (bool);

    /// @notice Withdraws the deposited ERC721s if the reserve price is not reached
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    function withdrawMultipleERC721FromNonWinningSlot(
        uint256 auctionId,
        uint256 slotIndex
    ) external returns (bool);

    /// @notice Withdraws the deposited ERC721 if the reserve price is not reached
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    /// @param nftSlotIndex The index of the NFT inside the particular slot - it is returned on depositERC721() call
    function withdrawERC721FromNonWinningSlot(
        uint256 auctionId,
        uint256 slotIndex,
        uint256 nftSlotIndex
    ) external returns (bool);

    /// @notice Cancels an auction which has not started yet
    /// @param auctionId The auction id
    function cancelAuction(uint256 auctionId) external returns (bool);

    /// @notice Whitelist multiple addresses which will be able to participate in the auction
    /// @param auctionId The auction id
    /// @param addressesToWhitelist The array of addresses which will be whitelisted
    function whitelistMultipleAddresses(
        uint256 auctionId,
        address[] calldata addressesToWhitelist
    ) external returns (bool);

    /// @notice Gets deposited erc721s for slot
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    function getDepositedNftsInSlot(uint256 auctionId, uint256 slotIndex)
        external
        view
        returns (DepositedERC721[] memory);

    /// @notice Gets the amount of deposited erc721s in slot
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    function getTotalDepositedNftsInSlot(uint256 auctionId, uint256 slotIndex)
        external
        view
        returns (uint256);

    /// @notice Gets slot winner for particular auction
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    function getSlotWinner(uint256 auctionId, uint256 slotIndex)
        external
        view
        returns (address);

    /// @notice Gets the bidder total bids in auction
    /// @param auctionId The auction id
    /// @param bidder The address of the bidder
    function getBidderBalance(uint256 auctionId, address bidder)
        external
        view
        returns (uint256);

    /// @notice Checks id an address is whitelisted for specific auction
    /// @param auctionId The auction id
    /// @param addressToCheck The address to be checked
    function isAddressWhitelisted(uint256 auctionId, address addressToCheck)
        external
        view
        returns (bool);

    /// @notice Withdraws the generated revenue from the auction to the auction owner
    /// @param auctionId The auction id
    function withdrawAuctionRevenue(uint256 auctionId) external returns (bool);

    /// @notice Claims and distributes the NFTs from a winning slot
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    function claimERC721Rewards(uint256 auctionId, uint256 slotIndex)
        external
        returns (bool);

    /// @notice Sets the percentage of the royalty which wil be kept from each sale
    /// @param royaltyFeeMantissa The royalty percentage
    function setRoyaltyFeeMantissa(uint256 royaltyFeeMantissa)
        external
        returns (uint256);

    /// @notice Withdraws the aggregated royalites amount of specific token to a specified address
    /// @param token The address of the token to withdraw
    /// @param to The address to which the royalties will be transfered
    function withdrawRoyalties(address token, address to)
        external
        returns (uint256);

    /// @notice Sets the minimum reserve price for auction slots
    /// @param auctionId The auction id
    /// @param minimumReserveValues The array of minimum reserve values to be set for each slot, starting from slot 1
    function setMinimumReserveForAuctionSlots(
        uint256 auctionId,
        uint256[] calldata minimumReserveValues
    ) external returns (bool);

    /// @notice Gets the minimum reserve price for auciton slot
    /// @param auctionId The auction id
    /// @param slotIndex The slot index
    function getMinimumReservePriceForSlot(uint256 auctionId, uint256 slotIndex)
        external
        view
        returns (uint256);
}

// SPDX-License-Identifier: Unlicense
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/introspection/ERC165.sol";

contract HasSecondarySaleFees is ERC165 {
    struct Fee {
        address payable recipient;
        uint256 value;
    }

    // id => fees
    mapping (uint256 => Fee[]) public fees;
    event SecondarySaleFees(uint256 tokenId, address[] recipients, uint[] bps);

    /*
     * bytes4(keccak256('getFeeBps(uint256)')) == 0x0ebd4c7f
     * bytes4(keccak256('getFeeRecipients(uint256)')) == 0xb9c4d9fb
     *
     * => 0x0ebd4c7f ^ 0xb9c4d9fb == 0xb7799584
     */
    bytes4 private constant _INTERFACE_ID_FEES = 0xb7799584;
    constructor() public {
        _registerInterface(_INTERFACE_ID_FEES);
    }

    function getFeeRecipients(uint256 id) external view returns (address payable[] memory) {
        Fee[] memory _fees = fees[id];
        address payable[] memory result = new address payable[](_fees.length);
        for (uint i = 0; i < _fees.length; i++) {
            result[i] = _fees[i].recipient;
        }
        return result;
    }

    function getFeeBps(uint256 id) external view returns (uint[] memory) {
        Fee[] memory _fees = fees[id];
        uint[] memory result = new uint[](_fees.length);
        for (uint i = 0; i < _fees.length; i++) {
            result[i] = _fees[i].value;
        }
        return result;
    }

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

pragma solidity >=0.6.0 <0.8.0;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "./IERC165.sol";

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts may inherit from this and call {_registerInterface} to declare
 * their support of an interface.
 */
abstract contract ERC165 is IERC165 {
    /*
     * bytes4(keccak256('supportsInterface(bytes4)')) == 0x01ffc9a7
     */
    bytes4 private constant _INTERFACE_ID_ERC165 = 0x01ffc9a7;

    /**
     * @dev Mapping of interface ids to whether or not it's supported.
     */
    mapping(bytes4 => bool) private _supportedInterfaces;

    constructor () internal {
        // Derived contracts need only register support for their own interfaces,
        // we register support for ERC165 itself here
        _registerInterface(_INTERFACE_ID_ERC165);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     *
     * Time complexity O(1), guaranteed to always use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return _supportedInterfaces[interfaceId];
    }

    /**
     * @dev Registers the contract as an implementer of the interface defined by
     * `interfaceId`. Support of the actual ERC165 interface is automatic and
     * registering its interface id is not required.
     *
     * See {IERC165-supportsInterface}.
     *
     * Requirements:
     *
     * - `interfaceId` cannot be the ERC165 invalid interface (`0xffffffff`).
     */
    function _registerInterface(bytes4 interfaceId) internal virtual {
        require(interfaceId != 0xffffffff, "ERC165: invalid interface id");
        _supportedInterfaces[interfaceId] = true;
    }
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
  "metadata": {
    "useLiteralContent": true
  },
  "libraries": {}
}