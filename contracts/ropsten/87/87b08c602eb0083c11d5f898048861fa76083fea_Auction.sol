// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

/** OpenZeppelin Dependencies */
import '@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';

import '../base/AuctionBase.sol';
import '../abstracts/ExternallyCallable.sol';

import '../libs/AxionSafeCast.sol';

contract Auction is IAuction, ExternallyCallable, AuctionBase {
    using AxionSafeCast for uint256;
    using SafeCastUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    //** Mapping */
    mapping(uint256 => Options) internal optionsOf;
    mapping(uint256 => AuctionReserves) internal reservesOf;
    mapping(address => EnumerableSetUpgradeable.UintSet) internal auctionsOf;
    mapping(uint256 => mapping(address => UserBid)) internal auctionBidOf;

    Settings internal settings;
    Addresses internal addresses;
    Contracts internal contracts;
    AuctionData[7] internal auctions; // 7 values for 7 days of the week

    /* UPGRADEABILITY: New variables must go below here. */

    /** Update Price of current auction
        Get current axion day
        Get uniswapLastPrice
        Set middlePrice
     */
    function _updatePrice(uint256 currentAuctionId) internal {
        /** Set reserves of */
        reservesOf[currentAuctionId].uniswapLastPrice = (getUniswapLastPrice() / 1e12).toUint64(); // div by 1e12 as in memory it's 18 dps and we store 6

        if (optionsOf[currentAuctionId].middlePriceDays == 1) {
            reservesOf[currentAuctionId].uniswapMiddlePrice = reservesOf[currentAuctionId]
                .uniswapLastPrice;
        } else {
            reservesOf[currentAuctionId].uniswapMiddlePrice = (getUniswapMiddlePriceForDays(
                currentAuctionId
            ) / 1e12)
                .toUint64();
        }
    }

    /**
        Bid- Set values for bid
     */
    function bid(
        address bidder,
        address ref,
        uint256 eth
    ) external override onlyExternalCaller returns (uint256) {
        uint256 currentAuctionId = getCurrentAuctionId();

        _saveAuctionData(currentAuctionId);
        _updatePrice(currentAuctionId);

        /** If referralsOn is true allow to set ref */
        if (optionsOf[currentAuctionId].referralsOn == true) {
            auctionBidOf[currentAuctionId][bidder].ref = ref;
        }

        /** Set auctionBid for bidder */
        auctionBidOf[currentAuctionId][bidder].eth += eth.toUint88();
        auctionBidOf[currentAuctionId][bidder].status = UserBidStatus.Active;

        auctionsOf[bidder].add(currentAuctionId);

        reservesOf[currentAuctionId].eth += (eth / 1e12).toUint48();

        // auction oversell check */
        uint256 tokensSold =
            (reservesOf[currentAuctionId].eth * reservesOf[currentAuctionId].uniswapMiddlePrice) /
                1e6;

        uint256 tokensSoldFinal =
            tokensSold +
                (tokensSold * optionsOf[currentAuctionId].discountPercent) /
                100 -
                (tokensSold * optionsOf[currentAuctionId].premiumPercent) /
                100;

        require(tokensSoldFinal <= reservesOf[currentAuctionId].token, 'AUCTION: Oversold');

        return currentAuctionId;
    }

    /**
        getUniswapLastPrice - Use uniswap router to determine current price of AXN per ETH
    */
    function getUniswapLastPrice() internal view returns (uint256) {
        address[] memory path = new address[](2);

        path[0] = contracts.uniswapRouter.WETH();
        path[1] = addresses.token;

        uint256 price = contracts.uniswapRouter.getAmountsOut(1e18, path)[1];

        return price;
    }

    /**
        getUniswapMiddlePriceForDays
            Use the "last known price" for the last {middlePriceDays} days to determine middle price by taking an average
     */
    function getUniswapMiddlePriceForDays(uint256 currentAuctionId)
        internal
        view
        returns (uint256)
    {
        uint256 index = currentAuctionId;
        uint256 sum;
        uint256 points;

        while (points != optionsOf[currentAuctionId].middlePriceDays) {
            if (reservesOf[index].uniswapLastPrice != 0) {
                sum += uint256(reservesOf[index].uniswapLastPrice) * 1e12;
                points++;
            }

            if (index == 0) break;

            index--;
        }

        if (sum == 0) return getUniswapLastPrice();
        else return sum / points;
    }

    /**
        withdraw - Withdraws an auction bid and stakes axion in staking contract

        @param auctionId {uint256} - Auction to withdraw from
        @param stakeDays {uint256} - # of days to stake in portal
     */
    function withdraw(uint256 auctionId, uint256 stakeDays) external {
        /** Require # of staking days < 5556 */
        require(stakeDays <= 5555, 'AUCTION: stakeDays > 5555');

        /** Ensure auctionId of withdraw is not todays auction, and user bid has not been withdrawn*/
        require(getCurrentAuctionId() > auctionId, 'AUCTION: Auction is active');
        require(
            auctionBidOf[auctionId][msg.sender].status == UserBidStatus.Active,
            "AUCTION: Bid is withdrawn or doesn't exist"
        );
        // Require the # of days staking > options
        require(
            stakeDays >= optionsOf[auctionId].autoStakeDays,
            'AUCTION: stakeDays < minimum days'
        );

        /** Call common withdraw functions */
        withdrawInternal(auctionBidOf[auctionId][msg.sender].eth, auctionId, stakeDays);
    }

    /**
        withdrawLegacy - Withdraws a legacy auction bid and stakes axion in staking contract

        @param auctionId {uint256} - Auction to withdraw from
        @param stakeDays {uint256} - # of days to stake in portal
     */
    function withdrawLegacy(uint256 auctionId, uint256 stakeDays) external {
        /** This stops a user from using withdrawLegacy twice, since the bid is put into memory at the end */
        require(auctionsOf[msg.sender].contains(auctionId) == false, 'AUCTION: Bid is v3.');

        /** Ensure stake days > options  */
        require(
            stakeDays >= auctions[auctionId % 7].options.autoStakeDays,
            'AUCTION: stakeDays < minimum days'
        );

        require(stakeDays <= 5555, 'AUCTION: stakeDays > 5555');

        require(getCurrentAuctionId() > auctionId, 'AUCTION: Auction is active');

        (uint256 eth, address ref, bool withdrawn) =
            contracts.auctionV2.auctionBidOf(auctionId, msg.sender);

        require(eth != 0, 'AUCTION: empty bid');
        require(withdrawn == false, 'AUCTION: withdrawn in v2');

        /** Bring v2 auction bid to v3 */
        auctionsOf[msg.sender].add(auctionId);

        auctionBidOf[auctionId][msg.sender].ref = ref;
        auctionBidOf[auctionId][msg.sender].eth += eth.toUint88();

        /** Common withdraw functionality */
        withdrawInternal(eth, auctionId, stakeDays);
    }

    /** Withdraw internal
        @param bidAmount {uint256}
        @param auctionId {uint256}
        @param stakeDays {uint256}
     */
    function withdrawInternal(
        uint256 bidAmount,
        uint256 auctionId,
        uint256 stakeDays
    ) internal {
        auctionBidOf[auctionId][msg.sender].status = UserBidStatus.Withdrawn;

        // Calculate payout for bidder
        uint256 bidPayout = getBidPayout(bidAmount, auctionId);

        uint256 oldPayout = bidPayout;
        //add bonus percentage based on years stake length
        if (stakeDays >= 350) {
            bidPayout += (bidPayout * (stakeDays / 350 + 5)) / 100; // multiply by percent divide by 100
        }

        //add 10% payout bonus if auction mode is regular
        uint8 auctionMode = auctions[auctionId % 7].mode;

        if (auctionMode == 0) {
            uint256 payoutBonus = oldPayout / 10;
            bidPayout = bidPayout + payoutBonus;
        }

        /** Call external stake for referrer and bidder */
        contracts.stakeMinter.externalStake(bidPayout, stakeDays, msg.sender);

        emit BidStake(msg.sender, bidPayout, auctionId, block.timestamp, stakeDays);
    }

    function getBidPayout(uint256 bidAmount, uint256 auctionId) internal returns (uint256) {
        if (auctionId <= settings.lastAuctionIdV2) {
            (uint256 ethInReserve, uint256 tokensInReserve, , uint256 uniswapMiddlePrice) =
                contracts.auctionV2.reservesOf(auctionId);

            uint256 day = auctionId % 7;

            return
                _calculatePayoutWithUniswap(
                    uniswapMiddlePrice,
                    bidAmount,
                    (bidAmount * tokensInReserve) / ethInReserve,
                    uint256(auctions[day].options.discountPercent),
                    uint256(auctions[day].options.premiumPercent)
                );
        } else {
            return
                _calculatePayoutWithUniswap(
                    uint256(reservesOf[auctionId].uniswapMiddlePrice) * 1e12,
                    bidAmount,
                    ((bidAmount * uint256(reservesOf[auctionId].token) * 1e12) /
                        uint256(reservesOf[auctionId].eth)) * 1e12,
                    uint256(optionsOf[auctionId].discountPercent),
                    uint256(optionsOf[auctionId].premiumPercent)
                );
        }
    }

    /** External Contract Caller functions 
        @param amount {uint256} - amount to add to next dailyAuction
    */
    function addTokensToNextAuction(uint256 amount) external override onlyExternalCaller {
        // Adds a specified amount of axion to tomorrows auction
        reservesOf[getCurrentAuctionId() + 1].token += (amount / 1e12).toUint64();
    }

    /** Calculate functions */
    function calculateNearestWeeklyAuction() public view returns (uint256) {
        uint256 currentAuctionId = getCurrentAuctionId();
        return currentAuctionId + ((7 - currentAuctionId) % 7);
    }

    /** Get current day of week
     * EX: friday = 0, saturday = 1, sunday = 2 etc...
     */
    function getCurrentDay() internal view returns (uint256) {
        uint256 currentAuctionId = getCurrentAuctionId();
        return currentAuctionId % 7;
    }

    function getCurrentAuctionId() public view returns (uint256) {
        return (block.timestamp - settings.contractStartTimestamp) / settings.secondsInDay;
    }

    /** Determine payout and overage
        @param uniswapMiddlePrice {uint256}
        @param amount {uint256} - Amount to use to determine overage
        @param payout {uint256} - payout
        @param discountPercent {uint256}
        @param premiumPercent {uint256}
     */
    function _calculatePayoutWithUniswap(
        uint256 uniswapMiddlePrice,
        uint256 amount,
        uint256 payout,
        uint256 discountPercent,
        uint256 premiumPercent
    ) internal pure returns (uint256) {
        // Get payout for user

        uint256 uniswapPayout = (uniswapMiddlePrice * amount) / 1e18;

        // Get payout with percentage based on discount, premium
        uint256 bidPayout =
            uniswapPayout +
                ((uniswapPayout * discountPercent) / 100) - // I dont think this is necessary
                ((uniswapPayout * premiumPercent) / 100);

        if (payout > bidPayout) {
            return bidPayout;
        } else {
            return payout;
        }
    }

    /** Determine amount of axion to mint for referrer based on amount
        @param amount {uint256} - amount of axion

        @return (uint256, uint256)
     */
    function _calculateRefAndUserAmountsToMint(uint256 auctionId, uint256 amount)
        private
        view
        returns (uint256, uint256)
    {
        uint256 toRefMintAmount = (amount * uint256(optionsOf[auctionId].referrerPercent)) / 100;
        uint256 toUserMintAmount = (amount * uint256(optionsOf[auctionId].referredPercent)) / 100;

        return (toRefMintAmount, toUserMintAmount);
    }

    /** Save auction data
        Determines if auction is over. If auction is over set lastAuctionId to currentAuctionId
    */
    function _saveAuctionData(uint256 currentAuctionId) internal {
        if (settings.lastAuctionId < currentAuctionId) {
            uint256 currentDay = getCurrentDay();

            reservesOf[currentAuctionId].filled = true;
            reservesOf[currentAuctionId].token += (uint256(auctions[currentDay].amountToFillBy) *
                1e6)
                .toUint64();

            optionsOf[currentAuctionId] = auctions[currentDay].options;

            // If last auction is undersold, roll to next weekly auction
            uint256 tokensSold =
                uint256(reservesOf[settings.lastAuctionId].eth) *
                    uint256(reservesOf[settings.lastAuctionId].uniswapMiddlePrice);

            tokensSold +=
                (((tokensSold * uint256(optionsOf[settings.lastAuctionId].discountPercent)) / 100) -
                    ((tokensSold * uint256(optionsOf[settings.lastAuctionId].premiumPercent)) /
                        100)) /
                1e6;

            if (tokensSold < reservesOf[settings.lastAuctionId].token) {
                reservesOf[calculateNearestWeeklyAuction()].token += (reservesOf[
                    settings.lastAuctionId
                ]
                    .token - tokensSold)
                    .toUint64();
            }

            emit AuctionIsOver(
                reservesOf[settings.lastAuctionId].eth,
                reservesOf[settings.lastAuctionId].token,
                settings.lastAuctionId
            );

            settings.lastAuctionId = currentAuctionId.toUint64();
        }
    }

    /** Public Setter Functions */
    function setReferrerPercentage(uint8 day, uint8 percent) external onlyManager {
        auctions[day].options.referrerPercent = percent;
    }

    function setReferredPercentage(uint8 day, uint8 percent) external onlyManager {
        auctions[day].options.referredPercent = percent;
    }

    function setReferralsOn(uint8 day, bool _referralsOn) external onlyManager {
        auctions[day].options.referralsOn = _referralsOn;
    }

    function setAutoStakeDays(uint8 day, uint16 _autoStakeDays) external onlyManager {
        auctions[day].options.autoStakeDays = _autoStakeDays;
    }

    function setDiscountPercent(uint8 day, uint8 percent) external onlyManager {
        auctions[day].options.discountPercent = percent;
    }

    function setPremiumPercent(uint8 day, uint8 percent) external onlyManager {
        auctions[day].options.premiumPercent = percent;
    }

    function setMiddlePriceDays(uint8 day, uint8 _middleDays) external onlyManager {
        auctions[day].options.middlePriceDays = _middleDays;
    }

    /** VCA Setters */
    /** @dev Set Auction Mode
        @param _day {uint8} 0 - 6 value. 0 represents Saturday, 6 Represents Friday
        @param _mode {uint8} 0 or 1. 1 VCA, 0 Normal
     */
    function setAuctionMode(uint8 _day, uint8 _mode) external onlyManager {
        auctions[_day].mode = _mode;
    }

    /** @dev Set Tokens of day
        @param day {uint8} 0 - 6 value. 0 represents Saturday, 6 Represents Friday
        @param coins {address[]} - Addresses to buy from uniswap
        @param percentages {uint8[]} - % of coin to buy, must add up to 100%
     */
    function setTokensOfDay(
        uint8 day,
        address[] calldata coins,
        uint8[] calldata percentages
    ) external onlyManager {
        AuctionData storage auction = auctions[day];

        auction.mode = 1;
        delete auction.tokens;

        uint8 percent = 0;
        for (uint8 i; i < coins.length; i++) {
            auction.tokens.push(VentureToken(coins[i], percentages[i]));
            percent += percentages[i];
            contracts.vcAuction.addDivToken(coins[i]);
        }

        require(percent == 100, 'AUCTION: Percentage for venture day must equal 100');
    }

    function setAuctionAmountToFillBy(uint8 day, uint128 amountToFillBy) external onlyManager {
        auctions[day].amountToFillBy = amountToFillBy;
    }

    /** Initialize */
    function initialize(address _manager, address _migrator) external initializer {
        _setupRole(MANAGER_ROLE, _manager);
        _setupRole(MIGRATOR_ROLE, _migrator);
    }

    function init(
        // Addresses
        address _mainToken,
        // Externally callable
        address _auctionBidder,
        address _nativeSwap,
        // Contracts
        address _stakeMinter,
        address _stakeBurner,
        address _auctionV2,
        address _vcAuction,
        address _uniswap
    ) external onlyMigrator {
        /** Roles */
        _setupRole(EXTERNAL_CALLER_ROLE, _auctionBidder);
        _setupRole(EXTERNAL_CALLER_ROLE, _nativeSwap);
        _setupRole(EXTERNAL_CALLER_ROLE, _stakeMinter);
        _setupRole(EXTERNAL_CALLER_ROLE, _stakeBurner);

        /** addresses */
        addresses.token = _mainToken;

        /** Contracts */
        contracts.auctionV2 = IAuctionV21(_auctionV2);
        contracts.vcAuction = IVCAuction(_vcAuction);
        contracts.stakeMinter = IStakeMinter(_stakeMinter);
        contracts.uniswapRouter = IUniswapV2Router02(_uniswap);
    }

    function restore(
        uint16 _autoStakeDays,
        uint8 _referrerPercent,
        uint8 _referredPercent,
        uint8 _discountPercent,
        uint8 _premiumPercent,
        uint8 _middlePriceDays,
        bool _referralsOn,
        uint64 _lastAuctionEventId,
        uint64 _contractStartTimestamp,
        uint64 _secondsInDay
    ) external onlyMigrator {
        for (uint256 i = 0; i < auctions.length; i++) {
            auctions[i].options.autoStakeDays = _autoStakeDays;
            auctions[i].options.referrerPercent = _referrerPercent;
            auctions[i].options.referredPercent = _referredPercent;
            auctions[i].options.discountPercent = _discountPercent;
            auctions[i].options.premiumPercent = _premiumPercent;
            auctions[i].options.middlePriceDays = _middlePriceDays;
            auctions[i].options.referralsOn = _referralsOn;
        }

        settings.lastAuctionId = _lastAuctionEventId;
        settings.lastAuctionIdV2 = _lastAuctionEventId;
        settings.contractStartTimestamp = _contractStartTimestamp;
        settings.secondsInDay = _secondsInDay;
    }

    /** Getter functions */
    function getTodaysMode() external view override returns (uint256) {
        return auctions[getCurrentDay()].mode;
    }

    function getTodaysTokens() external view override returns (VentureToken[] memory) {
        return auctions[getCurrentDay()].tokens;
    }

    function getAuctionModes() external view returns (uint8[7] memory) {
        uint8[7] memory auctionModes;

        for (uint8 i; i < auctions.length; i++) {
            auctionModes[i] = auctions[i].mode;
        }

        return auctionModes;
    }

    function getAuctionDay(uint8 day) external view returns (AuctionData memory) {
        return auctions[day];
    }

    function getTokensOfDay(uint8 _day) external view returns (VentureToken[] memory) {
        return auctions[_day].tokens;
    }

    function getDefaultOptionsOfDay(uint8 day) external view returns (Options memory) {
        return auctions[day].options;
    }

    function getOptionsOf(uint256 auctionId) external view returns (Options memory) {
        return optionsOf[auctionId];
    }

    function getAuctionReservesOf(uint256 auctionId)
        external
        view
        returns (AuctionReserves memory)
    {
        return reservesOf[auctionId];
    }

    function getAuctionsOf(address bidder) external view returns (uint256[] memory) {
        uint256[] memory auctionsIds = new uint256[](auctionsOf[bidder].length());

        for (uint256 i = 0; i < auctionsOf[bidder].length(); i++) {
            auctionsIds[i] = auctionsOf[bidder].at(i);
        }

        return auctionsIds;
    }

    function getAuctionBidOf(uint256 auctionId, address bidder)
        external
        view
        returns (UserBid memory)
    {
        return auctionBidOf[auctionId][bidder];
    }

    function getSettings() external view returns (Settings memory) {
        return settings;
    }

    function getAuctionData() external view returns (AuctionData[7] memory) {
        return auctions;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Wrappers over Solidity's uintXX/intXX casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 *
 * Can be combined with {SafeMath} and {SignedSafeMath} to extend it to smaller types, by performing
 * all math on `uint256` and `int256` and then downcasting.
 */
library SafeCastUpgradeable {
    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value < 2**128, "SafeCast: value doesn\'t fit in 128 bits");
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value < 2**64, "SafeCast: value doesn\'t fit in 64 bits");
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        require(value < 2**32, "SafeCast: value doesn\'t fit in 32 bits");
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        require(value < 2**16, "SafeCast: value doesn\'t fit in 16 bits");
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits.
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        require(value < 2**8, "SafeCast: value doesn\'t fit in 8 bits");
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "SafeCast: value must be positive");
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v3.1._
     */
    function toInt128(int256 value) internal pure returns (int128) {
        require(value >= -2**127 && value < 2**127, "SafeCast: value doesn\'t fit in 128 bits");
        return int128(value);
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v3.1._
     */
    function toInt64(int256 value) internal pure returns (int64) {
        require(value >= -2**63 && value < 2**63, "SafeCast: value doesn\'t fit in 64 bits");
        return int64(value);
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v3.1._
     */
    function toInt32(int256 value) internal pure returns (int32) {
        require(value >= -2**31 && value < 2**31, "SafeCast: value doesn\'t fit in 32 bits");
        return int32(value);
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v3.1._
     */
    function toInt16(int256 value) internal pure returns (int16) {
        require(value >= -2**15 && value < 2**15, "SafeCast: value doesn\'t fit in 16 bits");
        return int16(value);
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits.
     *
     * _Available since v3.1._
     */
    function toInt8(int256 value) internal pure returns (int8) {
        require(value >= -2**7 && value < 2**7, "SafeCast: value doesn\'t fit in 8 bits");
        return int8(value);
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        require(value < 2**255, "SafeCast: value doesn't fit in an int256");
        return int256(value);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 */
library EnumerableSetUpgradeable {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;

        // Position of the value in the `values` array, plus 1 because index 0
        // means a value is not in the set.
        mapping (bytes32 => uint256) _indexes;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._indexes[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We read and store the value's index to prevent multiple reads from the same storage slot
        uint256 valueIndex = set._indexes[value];

        if (valueIndex != 0) { // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 toDeleteIndex = valueIndex - 1;
            uint256 lastIndex = set._values.length - 1;

            // When the value to delete is the last one, the swap operation is unnecessary. However, since this occurs
            // so rarely, we still do the swap anyway to avoid the gas cost of adding an 'if' statement.

            bytes32 lastvalue = set._values[lastIndex];

            // Move the last value to the index where the value to delete is
            set._values[toDeleteIndex] = lastvalue;
            // Update the index for the moved value
            set._indexes[lastvalue] = toDeleteIndex + 1; // All indexes are 1-based

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the index for the deleted slot
            delete set._indexes[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._indexes[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        require(set._values.length > index, "EnumerableSet: index out of bounds");
        return set._values[index];
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }


    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

// Abstarcts
import '../abstracts/Migrateable.sol';
import '../abstracts/Manageable.sol';
import '../abstracts/ExternallyCallable.sol';

// Interfaces
import '../interfaces/IToken.sol';
import '../interfaces/IAuction.sol';
import '../interfaces/IVCAuction.sol';
import '../interfaces/IAuctionV21.sol';
import '../interfaces/IStakeMinter.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

contract AuctionBase is Migrateable, Manageable, ExternallyCallable {
    /** Events */
    event BidStake(
        address indexed account,
        uint256 value,
        uint256 indexed auctionId,
        uint256 time,
        uint256 stakeDays
    );

    event AuctionIsOver(uint256 eth, uint256 token, uint256 indexed auctionId);

    /** Structs */
    struct AuctionReserves {
        bool filled; // fill auctions on first bid/withdraw of day
        uint8 mode;
        uint48 eth; // 1e-6 Amount of Eth in the auction
        uint64 token; // 1e-6 Amount of Axn in auction for day
        uint64 uniswapLastPrice; // 1e-6 Last known uniswap price from last bid
        uint64 uniswapMiddlePrice; // 1e-6 Using middle price days to calculate avg price
    }

    enum UserBidStatus {Unknown, Withdrawn, Active}

    struct UserBid {
        uint88 eth; // Amount of ethereum
        address ref; // Referrer address for bid
        UserBidStatus status;
    }

    struct Contracts {
        IAuctionV21 auctionV2;
        IVCAuction vcAuction;
        IStakeMinter stakeMinter;
        IUniswapV2Router02 uniswapRouter;
    }

    struct Options {
        uint16 autoStakeDays; // # of days bidder must stake once axion is won from auction
        uint8 referrerPercent; // Referral Bonus %
        uint8 referredPercent; // Referral Bonus %
        uint8 discountPercent; // Discount in comparison to uniswap price in auction
        uint8 premiumPercent; // Premium in comparions to unsiwap price in auction
        uint8 middlePriceDays; // When calculating auction price this is used to determine average
        bool referralsOn; // If on referrals are used on auction
    }

    struct Addresses {
        address token;
    }

    struct Settings {
        uint64 lastAuctionId; // Index for Auction
        uint64 lastAuctionIdV2; // Last index for layer 1 auction - probably won't need
        uint64 contractStartTimestamp; // Beginning of contract
        uint64 secondsInDay; // # of seconds per "axion day" (86400)
    }

    struct AuctionData {
        uint8 mode; // 1 = VCA, 0 = Normal Auction
        uint128 amountToFillBy; // 0 decimal points
        VentureToken[] tokens; // Tokens to buy in VCA
        Options options;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract ExternallyCallable is AccessControlUpgradeable {
    bytes32 public constant EXTERNAL_CALLER_ROLE = keccak256('EXTERNAL_CALLER_ROLE');

    modifier onlyExternalCaller() {
        require(
            hasRole(EXTERNAL_CALLER_ROLE, msg.sender),
            'Caller is not allowed'
        );
        _;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

library AxionSafeCast {
    function toUint24(uint256 value) internal pure returns (uint24) {
        require(value < 2**24, "SafeCast: value doesn't fit in 24 bits");
        return uint24(value);
    }

    function toUint40(uint256 value) internal pure returns (uint40) {
        require(value < 2**40, "SafeCast: value doesn't fit in 40 bits");
        return uint40(value);
    }

    function toUint48(uint256 value) internal pure returns (uint48) {
        require(value < 2**48, "SafeCast: value doesn't fit in 48 bits");
        return uint48(value);
    }

    function toUint72(uint256 value) internal pure returns (uint72) {
        require(value < 2**72, "SafeCast: value doesn't fit in 72 bits");
        return uint72(value);
    }

    function toUint88(uint256 value) internal pure returns (uint88) {
        require(value < 2**88, "SafeCast: value doesn't fit in 88 bits");
        return uint88(value);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract Migrateable is AccessControlUpgradeable {
    bytes32 public constant MIGRATOR_ROLE = keccak256("MIGRATOR_ROLE");

    modifier onlyMigrator() {
        require(
            hasRole(MIGRATOR_ROLE, msg.sender),
            "Caller is not a migrator"
        );
        _;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

abstract contract Manageable is AccessControlUpgradeable {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    modifier onlyManager() {
        require(
            hasRole(MANAGER_ROLE, msg.sender),
            "Caller is not a manager"
        );
        _;
    }

    /** Roles management - only for multi sig address */
    function setupRole(bytes32 role, address account) external onlyManager {
        _setupRole(role, account);
    }

    function isManager(address account) external view returns (bool) {
        return hasRole(MANAGER_ROLE, account);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';

interface IToken is IERC20Upgradeable {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

struct VentureToken {
    address coin; // address of token to buy from swap
    uint96 percentage; // % of token to buy NOTE: (On a VCA day all Venture tokens % should add up to 100%)
}

interface IAuction {
    function addTokensToNextAuction(uint256 amount) external;

    function getTodaysMode() external returns (uint256);

    function getTodaysTokens() external returns (VentureToken[] memory);

    function bid(
        address bidder,
        address ref,
        uint256 eth
    ) external returns (uint256);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

interface IVCAuction {
    function withdrawDivTokensFromTo(address from, address payable to)
        external;

    function addTotalSharesOfAndRebalance(address staker, uint256 shares)
        external;

    function subTotalSharesOfAndRebalance(address staker, uint256 shares)
        external;

    function updateTokenPricePerShare(
        address payable bidderAddress,
        address tokenAddress,
        uint256 amountBought
    ) external payable;

    function addDivToken(address tokenAddress) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

interface IAuctionV21 {
    function auctionBidOf(uint256, address)
        external
        returns (
            uint256,
            address,
            bool
        );

    function reservesOf(uint256)
        external
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

interface IStakeMinter {
    function externalStake(
        uint256 amount,
        uint256 stakingDays,
        address staker
    ) external;
}

pragma solidity >=0.6.2;

import './IUniswapV2Router01.sol';

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../utils/ContextUpgradeable.sol";
import "../utils/introspection/ERC165Upgradeable.sol";
import "../proxy/utils/Initializable.sol";

/**
 * @dev External interface of AccessControl declared to support ERC165 detection.
 */
interface IAccessControlUpgradeable {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
}

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it.
 */
abstract contract AccessControlUpgradeable is Initializable, ContextUpgradeable, IAccessControlUpgradeable, ERC165Upgradeable {
    function __AccessControl_init() internal initializer {
        __Context_init_unchained();
        __ERC165_init_unchained();
        __AccessControl_init_unchained();
    }

    function __AccessControl_init_unchained() internal initializer {
    }
    struct RoleData {
        mapping (address => bool) members;
        bytes32 adminRole;
    }

    mapping (bytes32 => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted signaling this.
     *
     * _Available since v3.1._
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call, an admin role
     * bearer except when using {_setupRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControlUpgradeable).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return _roles[role].members[account];
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view override returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) public virtual override {
        require(hasRole(getRoleAdmin(role), _msgSender()), "AccessControl: sender must be an admin to grant");

        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) public virtual override {
        require(hasRole(getRoleAdmin(role), _msgSender()), "AccessControl: sender must be an admin to revoke");

        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `account`.
     */
    function renounceRole(bytes32 role, address account) public virtual override {
        require(account == _msgSender(), "AccessControl: can only renounce roles for self");

        _revokeRole(role, account);
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event. Note that unlike {grantRole}, this function doesn't perform any
     * checks on the calling account.
     *
     * [WARNING]
     * ====
     * This function should only be called from the constructor when setting
     * up the initial roles for the system.
     *
     * Using this function in any other way is effectively circumventing the admin
     * system imposed by {AccessControl}.
     * ====
     */
    function _setupRole(bytes32 role, address account) internal virtual {
        _grantRole(role, account);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        emit RoleAdminChanged(role, getRoleAdmin(role), adminRole);
        _roles[role].adminRole = adminRole;
    }

    function _grantRole(bytes32 role, address account) private {
        if (!hasRole(role, account)) {
            _roles[role].members[account] = true;
            emit RoleGranted(role, account, _msgSender());
        }
    }

    function _revokeRole(bytes32 role, address account) private {
        if (hasRole(role, account)) {
            _roles[role].members[account] = false;
            emit RoleRevoked(role, account, _msgSender());
        }
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "../proxy/utils/Initializable.sol";

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
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IERC165Upgradeable.sol";
import "../../proxy/utils/Initializable.sol";

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 *
 * Alternatively, {ERC165Storage} provides an easier to use but more expensive implementation.
 */
abstract contract ERC165Upgradeable is Initializable, IERC165Upgradeable {
    function __ERC165_init() internal initializer {
        __ERC165_init_unchained();
    }

    function __ERC165_init_unchained() internal initializer {
    }
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165Upgradeable).interfaceId;
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

// solhint-disable-next-line compiler-version
pragma solidity ^0.8.0;

import "../../utils/AddressUpgradeable.sol";

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since a proxied contract can't have a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {UpgradeableProxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 */
abstract contract Initializable {

    /**
     * @dev Indicates that the contract has been initialized.
     */
    bool private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializer() {
        require(_initializing || !_initialized, "Initializable: contract is already initialized");

        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library AddressUpgradeable {
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
interface IERC165Upgradeable {
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

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20Upgradeable {
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

pragma solidity >=0.6.2;

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

{
  "optimizer": {
    "enabled": true,
    "runs": 50000
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