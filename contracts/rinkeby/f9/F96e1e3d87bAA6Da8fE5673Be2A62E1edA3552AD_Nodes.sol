// SPDX-License-Identifier: AGPL-3.0-only

/*
    Bounty.sol - SKALE Manager
    Copyright (C) 2020-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "./delegation/DelegationController.sol";
import "./delegation/PartialDifferences.sol";
import "./delegation/TimeHelpers.sol";
import "./delegation/ValidatorService.sol";

import "./ConstantsHolder.sol";
import "./Nodes.sol";
import "./Permissions.sol";


contract BountyV2 is Permissions {
    using PartialDifferences for PartialDifferences.Value;
    using PartialDifferences for PartialDifferences.Sequence;

    struct BountyHistory {
        uint month;
        uint bountyPaid;
    }
    
    uint public constant YEAR1_BOUNTY = 3850e5 * 1e18;
    uint public constant YEAR2_BOUNTY = 3465e5 * 1e18;
    uint public constant YEAR3_BOUNTY = 3080e5 * 1e18;
    uint public constant YEAR4_BOUNTY = 2695e5 * 1e18;
    uint public constant YEAR5_BOUNTY = 2310e5 * 1e18;
    uint public constant YEAR6_BOUNTY = 1925e5 * 1e18;
    uint public constant EPOCHS_PER_YEAR = 12;
    uint public constant SECONDS_PER_DAY = 24 * 60 * 60;
    uint public constant BOUNTY_WINDOW_SECONDS = 3 * SECONDS_PER_DAY;
    
    uint private _nextEpoch;
    uint private _epochPool;
    uint private _bountyWasPaidInCurrentEpoch;
    bool public bountyReduction;
    uint public nodeCreationWindowSeconds;

    PartialDifferences.Value private _effectiveDelegatedSum;
    // validatorId   amount of nodes
    mapping (uint => uint) public nodesByValidator; // deprecated

    // validatorId => BountyHistory
    mapping (uint => BountyHistory) private _bountyHistory;

    function calculateBounty(uint nodeIndex)
        external
        allow("SkaleManager")
        returns (uint)
    {
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getContract("ConstantsHolder"));
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getContract("TimeHelpers"));
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        
        require(
            _getNextRewardTimestamp(nodeIndex, nodes, timeHelpers) <= now,
            "Transaction is sent too early"
        );

        uint validatorId = nodes.getValidatorId(nodeIndex);
        if (nodesByValidator[validatorId] > 0) {
            delete nodesByValidator[validatorId];
        }

        uint currentMonth = timeHelpers.getCurrentMonth();
        _refillEpochPool(currentMonth, timeHelpers, constantsHolder);
        _prepareBountyHistory(validatorId, currentMonth);

        uint bounty = _calculateMaximumBountyAmount(
            _epochPool,
            _effectiveDelegatedSum.getAndUpdateValue(currentMonth),
            _bountyWasPaidInCurrentEpoch,
            nodeIndex,
            _bountyHistory[validatorId].bountyPaid,
            delegationController.getAndUpdateEffectiveDelegatedToValidator(validatorId, currentMonth),
            delegationController.getAndUpdateDelegatedToValidatorNow(validatorId),
            constantsHolder,
            nodes
        );
        _bountyHistory[validatorId].bountyPaid = _bountyHistory[validatorId].bountyPaid.add(bounty);

        bounty = _reduceBounty(
            bounty,
            nodeIndex,
            nodes,
            constantsHolder
        );
        
        _epochPool = _epochPool.sub(bounty);
        _bountyWasPaidInCurrentEpoch = _bountyWasPaidInCurrentEpoch.add(bounty);

        return bounty;
    }

    function enableBountyReduction() external onlyOwner {
        bountyReduction = true;
    }

    function disableBountyReduction() external onlyOwner {
        bountyReduction = false;
    }

    function setNodeCreationWindowSeconds(uint window) external allow("Nodes") {
        nodeCreationWindowSeconds = window;
    }

    function handleDelegationAdd(
        uint amount,
        uint month
    )
        external
        allow("DelegationController")
    {
        _effectiveDelegatedSum.addToValue(amount, month);
    }

    function handleDelegationRemoving(
        uint amount,
        uint month
    )
        external
        allow("DelegationController")
    {
        _effectiveDelegatedSum.subtractFromValue(amount, month);
    }

    function populate() external onlyOwner {
        ValidatorService validatorService = ValidatorService(contractManager.getValidatorService());
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getTimeHelpers());

        uint currentMonth = timeHelpers.getCurrentMonth();

        // clean existing data
        for (
            uint i = _effectiveDelegatedSum.firstUnprocessedMonth;
            i < _effectiveDelegatedSum.lastChangedMonth.add(1);
            ++i
        )
        {
            delete _effectiveDelegatedSum.addDiff[i];
            delete _effectiveDelegatedSum.subtractDiff[i];
        }
        delete _effectiveDelegatedSum.value;
        delete _effectiveDelegatedSum.lastChangedMonth;
        _effectiveDelegatedSum.firstUnprocessedMonth = currentMonth;
        
        uint[] memory validators = validatorService.getTrustedValidators();
        for (uint i = 0; i < validators.length; ++i) {
            uint validatorId = validators[i];
            uint currentEffectiveDelegated =
                delegationController.getAndUpdateEffectiveDelegatedToValidator(validatorId, currentMonth);
            uint[] memory effectiveDelegated = delegationController.getEffectiveDelegatedValuesByValidator(validatorId);
            if (effectiveDelegated.length > 0) {
                assert(currentEffectiveDelegated == effectiveDelegated[0]);
            }
            uint added = 0;
            for (uint j = 0; j < effectiveDelegated.length; ++j) {
                if (effectiveDelegated[j] != added) {
                    if (effectiveDelegated[j] > added) {
                        _effectiveDelegatedSum.addToValue(effectiveDelegated[j].sub(added), currentMonth + j);
                    } else {
                        _effectiveDelegatedSum.subtractFromValue(added.sub(effectiveDelegated[j]), currentMonth + j);
                    }
                    added = effectiveDelegated[j];
                }
            }
            delete effectiveDelegated;
        }
    }

    function estimateBounty(uint nodeIndex) external view returns (uint) {
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getContract("ConstantsHolder"));
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getContract("TimeHelpers"));
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );

        uint currentMonth = timeHelpers.getCurrentMonth();
        uint validatorId = nodes.getValidatorId(nodeIndex);

        uint stagePoolSize;
        (stagePoolSize, ) = _getEpochPool(currentMonth, timeHelpers, constantsHolder);

        return _calculateMaximumBountyAmount(
            stagePoolSize,
            _effectiveDelegatedSum.getValue(currentMonth),
            _nextEpoch == currentMonth.add(1) ? _bountyWasPaidInCurrentEpoch : 0,
            nodeIndex,
            _getBountyPaid(validatorId, currentMonth),
            delegationController.getEffectiveDelegatedToValidator(validatorId, currentMonth),
            delegationController.getDelegatedToValidator(validatorId, currentMonth),
            constantsHolder,
            nodes
        );
    }

    function getNextRewardTimestamp(uint nodeIndex) external view returns (uint) {
        return _getNextRewardTimestamp(
            nodeIndex,
            Nodes(contractManager.getContract("Nodes")),
            TimeHelpers(contractManager.getContract("TimeHelpers"))
        );
    }

    function getEffectiveDelegatedSum() external view returns (uint[] memory) {
        return _effectiveDelegatedSum.getValues();
    }

    function initialize(address contractManagerAddress) public override initializer {
        Permissions.initialize(contractManagerAddress);
        _nextEpoch = 0;
        _epochPool = 0;
        _bountyWasPaidInCurrentEpoch = 0;
        bountyReduction = false;
        nodeCreationWindowSeconds = 3 * SECONDS_PER_DAY;
    }

    // private

    function _calculateMaximumBountyAmount(
        uint epochPoolSize,
        uint effectiveDelegatedSum,
        uint bountyWasPaidInCurrentEpoch,
        uint nodeIndex,
        uint bountyPaidToTheValidator,
        uint effectiveDelegated,
        uint delegated,
        ConstantsHolder constantsHolder,
        Nodes nodes
    )
        private
        view
        returns (uint)
    {
        if (nodes.isNodeLeft(nodeIndex)) {
            return 0;
        }

        if (now < constantsHolder.launchTimestamp()) {
            // network is not launched
            // bounty is turned off
            return 0;
        }
        
        if (effectiveDelegatedSum == 0) {
            // no delegations in the system
            return 0;
        }

        if (constantsHolder.msr() == 0) {
            return 0;
        }

        uint bounty = _calculateBountyShare(
            epochPoolSize.add(bountyWasPaidInCurrentEpoch),
            effectiveDelegated,
            effectiveDelegatedSum,
            delegated.div(constantsHolder.msr()),
            bountyPaidToTheValidator
        );

        return bounty;
    }

    function _calculateBountyShare(
        uint monthBounty,
        uint effectiveDelegated,
        uint effectiveDelegatedSum,
        uint maxNodesAmount,
        uint paidToValidator
    )
        private
        pure
        returns (uint)
    {
        if (maxNodesAmount > 0) {
            uint totalBountyShare = monthBounty
                .mul(effectiveDelegated)
                .div(effectiveDelegatedSum);
            return _min(
                totalBountyShare.div(maxNodesAmount),
                totalBountyShare.sub(paidToValidator)
            );
        } else {
            return 0;
        }
    }

    function _getFirstEpoch(TimeHelpers timeHelpers, ConstantsHolder constantsHolder) private view returns (uint) {
        return timeHelpers.timestampToMonth(constantsHolder.launchTimestamp());
    }

    function _getEpochPool(
        uint currentMonth,
        TimeHelpers timeHelpers,
        ConstantsHolder constantsHolder
    )
        private
        view
        returns (uint epochPool, uint nextEpoch)
    {
        epochPool = _epochPool;
        for (nextEpoch = _nextEpoch; nextEpoch <= currentMonth; ++nextEpoch) {
            epochPool = epochPool.add(_getEpochReward(nextEpoch, timeHelpers, constantsHolder));
        }
    }

    function _refillEpochPool(uint currentMonth, TimeHelpers timeHelpers, ConstantsHolder constantsHolder) private {
        uint epochPool;
        uint nextEpoch;
        (epochPool, nextEpoch) = _getEpochPool(currentMonth, timeHelpers, constantsHolder);
        if (_nextEpoch < nextEpoch) {
            (_epochPool, _nextEpoch) = (epochPool, nextEpoch);
            _bountyWasPaidInCurrentEpoch = 0;
        }
    }

    function _getEpochReward(
        uint epoch,
        TimeHelpers timeHelpers,
        ConstantsHolder constantsHolder
    )
        private
        view
        returns (uint)
    {
        uint firstEpoch = _getFirstEpoch(timeHelpers, constantsHolder);
        if (epoch < firstEpoch) {
            return 0;
        }
        uint epochIndex = epoch.sub(firstEpoch);
        uint year = epochIndex.div(EPOCHS_PER_YEAR);
        if (year >= 6) {
            uint power = year.sub(6).div(3).add(1);
            if (power < 256) {
                return YEAR6_BOUNTY.div(2 ** power).div(EPOCHS_PER_YEAR);
            } else {
                return 0;
            }
        } else {
            uint[6] memory customBounties = [
                YEAR1_BOUNTY,
                YEAR2_BOUNTY,
                YEAR3_BOUNTY,
                YEAR4_BOUNTY,
                YEAR5_BOUNTY,
                YEAR6_BOUNTY
            ];
            return customBounties[year].div(EPOCHS_PER_YEAR);
        }
    }

    function _reduceBounty(
        uint bounty,
        uint nodeIndex,
        Nodes nodes,
        ConstantsHolder constants
    )
        private
        returns (uint reducedBounty)
    {
        if (!bountyReduction) {
            return bounty;
        }

        reducedBounty = bounty;

        if (!nodes.checkPossibilityToMaintainNode(nodes.getValidatorId(nodeIndex), nodeIndex)) {
            reducedBounty = reducedBounty.div(constants.MSR_REDUCING_COEFFICIENT());
        }
    }

    function _prepareBountyHistory(uint validatorId, uint currentMonth) private {
        if (_bountyHistory[validatorId].month < currentMonth) {
            _bountyHistory[validatorId].month = currentMonth;
            delete _bountyHistory[validatorId].bountyPaid;
        }
    }

    function _getBountyPaid(uint validatorId, uint month) private view returns (uint) {
        require(_bountyHistory[validatorId].month <= month, "Can't get bounty paid");
        if (_bountyHistory[validatorId].month == month) {
            return _bountyHistory[validatorId].bountyPaid;
        } else {
            return 0;
        }
    }

    function _getNextRewardTimestamp(uint nodeIndex, Nodes nodes, TimeHelpers timeHelpers) private view returns (uint) {
        uint lastRewardTimestamp = nodes.getNodeLastRewardDate(nodeIndex);
        uint lastRewardMonth = timeHelpers.timestampToMonth(lastRewardTimestamp);
        uint lastRewardMonthStart = timeHelpers.monthToTimestamp(lastRewardMonth);
        uint timePassedAfterMonthStart = lastRewardTimestamp.sub(lastRewardMonthStart);
        uint currentMonth = timeHelpers.getCurrentMonth();
        assert(lastRewardMonth <= currentMonth);

        if (lastRewardMonth == currentMonth) {
            uint nextMonthStart = timeHelpers.monthToTimestamp(currentMonth.add(1));
            uint nextMonthFinish = timeHelpers.monthToTimestamp(lastRewardMonth.add(2));
            if (lastRewardTimestamp < lastRewardMonthStart.add(nodeCreationWindowSeconds)) {
                return nextMonthStart.sub(BOUNTY_WINDOW_SECONDS);
            } else {
                return _min(nextMonthStart.add(timePassedAfterMonthStart), nextMonthFinish.sub(BOUNTY_WINDOW_SECONDS));
            }
        } else if (lastRewardMonth.add(1) == currentMonth) {
            uint currentMonthStart = timeHelpers.monthToTimestamp(currentMonth);
            uint currentMonthFinish = timeHelpers.monthToTimestamp(currentMonth.add(1));
            return _min(
                currentMonthStart.add(_max(timePassedAfterMonthStart, nodeCreationWindowSeconds)),
                currentMonthFinish.sub(BOUNTY_WINDOW_SECONDS)
            );
        } else {
            uint currentMonthStart = timeHelpers.monthToTimestamp(currentMonth);
            return currentMonthStart.add(nodeCreationWindowSeconds);
        }
    }

    function _min(uint a, uint b) private pure returns (uint) {
        if (a < b) {
            return a;
        } else {
            return b;
        }
    }

    function _max(uint a, uint b) private pure returns (uint) {
        if (a < b) {
            return b;
        } else {
            return a;
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    DelegationController.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777.sol";

import "../BountyV2.sol";
import "../Nodes.sol";
import "../Permissions.sol";
import "../utils/FractionUtils.sol";
import "../utils/MathUtils.sol";

import "./DelegationPeriodManager.sol";
import "./PartialDifferences.sol";
import "./Punisher.sol";
import "./TokenState.sol";
import "./ValidatorService.sol";

/**
 * @title Delegation Controller
 * @dev This contract performs all delegation functions including delegation
 * requests, and undelegation, etc.
 * 
 * Delegators and validators may both perform delegations. Validators who perform
 * delegations to themselves are effectively self-delegating or self-bonding.
 * 
 * IMPORTANT: Undelegation may be requested at any time, but undelegation is only
 * performed at the completion of the current delegation period.
 * 
 * Delegated tokens may be in one of several states:
 * 
 * - PROPOSED: token holder proposes tokens to delegate to a validator.
 * - ACCEPTED: token delegations are accepted by a validator and are locked-by-delegation.
 * - CANCELED: token holder cancels delegation proposal. Only allowed before the proposal is accepted by the validator.
 * - REJECTED: token proposal expires at the UTC start of the next month.
 * - DELEGATED: accepted delegations are delegated at the UTC start of the month.
 * - UNDELEGATION_REQUESTED: token holder requests delegations to undelegate from the validator.
 * - COMPLETED: undelegation request is completed at the end of the delegation period.
 */
contract DelegationController is Permissions, ILocker {
    using MathUtils for uint;
    using PartialDifferences for PartialDifferences.Sequence;
    using PartialDifferences for PartialDifferences.Value;
    using FractionUtils for FractionUtils.Fraction;
    
    uint public constant UNDELEGATION_PROHIBITION_WINDOW_SECONDS = 3 * 24 * 60 * 60;

    enum State {
        PROPOSED,
        ACCEPTED,
        CANCELED,
        REJECTED,
        DELEGATED,
        UNDELEGATION_REQUESTED,
        COMPLETED
    }

    struct Delegation {
        address holder; // address of token owner
        uint validatorId;
        uint amount;
        uint delegationPeriod;
        uint created; // time of delegation creation
        uint started; // month when a delegation becomes active
        uint finished; // first month after a delegation ends
        string info;
    }

    struct SlashingLogEvent {
        FractionUtils.Fraction reducingCoefficient;
        uint nextMonth;
    }

    struct SlashingLog {
        //      month => slashing event
        mapping (uint => SlashingLogEvent) slashes;
        uint firstMonth;
        uint lastMonth;
    }

    struct DelegationExtras {
        uint lastSlashingMonthBeforeDelegation;
    }

    struct SlashingEvent {
        FractionUtils.Fraction reducingCoefficient;
        uint validatorId;
        uint month;
    }

    struct SlashingSignal {
        address holder;
        uint penalty;
    }

    struct LockedInPending {
        uint amount;
        uint month;
    }

    struct FirstDelegationMonth {
        // month
        uint value;
        //validatorId => month
        mapping (uint => uint) byValidator;
    }

    struct ValidatorsStatistics {
        // number of validators
        uint number;
        //validatorId => bool - is Delegated or not
        mapping (uint => uint) delegated;
    }

    /**
     * @dev Emitted when a delegation is proposed to a validator.
     */
    event DelegationProposed(
        uint delegationId
    );

    /**
     * @dev Emitted when a delegation is accepted by a validator.
     */
    event DelegationAccepted(
        uint delegationId
    );

    /**
     * @dev Emitted when a delegation is cancelled by the delegator.
     */
    event DelegationRequestCanceledByUser(
        uint delegationId
    );

    /**
     * @dev Emitted when a delegation is requested to undelegate.
     */
    event UndelegationRequested(
        uint delegationId
    );

    /// @dev delegations will never be deleted to index in this array may be used like delegation id
    Delegation[] public delegations;

    // validatorId => delegationId[]
    mapping (uint => uint[]) public delegationsByValidator;

    //        holder => delegationId[]
    mapping (address => uint[]) public delegationsByHolder;

    // delegationId => extras
    mapping(uint => DelegationExtras) private _delegationExtras;

    // validatorId => sequence
    mapping (uint => PartialDifferences.Value) private _delegatedToValidator;
    // validatorId => sequence
    mapping (uint => PartialDifferences.Sequence) private _effectiveDelegatedToValidator;

    // validatorId => slashing log
    mapping (uint => SlashingLog) private _slashesOfValidator;

    //        holder => sequence
    mapping (address => PartialDifferences.Value) private _delegatedByHolder;
    //        holder =>   validatorId => sequence
    mapping (address => mapping (uint => PartialDifferences.Value)) private _delegatedByHolderToValidator;
    //        holder =>   validatorId => sequence
    mapping (address => mapping (uint => PartialDifferences.Sequence)) private _effectiveDelegatedByHolderToValidator;

    SlashingEvent[] private _slashes;
    //        holder => index in _slashes;
    mapping (address => uint) private _firstUnprocessedSlashByHolder;

    //        holder =>   validatorId => month
    mapping (address => FirstDelegationMonth) private _firstDelegationMonth;

    //        holder => locked in pending
    mapping (address => LockedInPending) private _lockedInPendingDelegations;

    mapping (address => ValidatorsStatistics) private _numberOfValidatorsPerDelegator;

    /**
     * @dev Modifier to make a function callable only if delegation exists.
     */
    modifier checkDelegationExists(uint delegationId) {
        require(delegationId < delegations.length, "Delegation does not exist");
        _;
    }

    /**
     * @dev Update and return a validator's delegations.
     */
    function getAndUpdateDelegatedToValidatorNow(uint validatorId) external returns (uint) {
        return _getAndUpdateDelegatedToValidator(validatorId, _getCurrentMonth());
    }

    /**
     * @dev Update and return the amount delegated.
     */
    function getAndUpdateDelegatedAmount(address holder) external returns (uint) {
        return _getAndUpdateDelegatedByHolder(holder);
    }

    /**
     * @dev Update and return the effective amount delegated (minus slash) for
     * the given month.
     */
    function getAndUpdateEffectiveDelegatedByHolderToValidator(address holder, uint validatorId, uint month) external
        allow("Distributor") returns (uint effectiveDelegated)
    {
        SlashingSignal[] memory slashingSignals = _processAllSlashesWithoutSignals(holder);
        effectiveDelegated = _effectiveDelegatedByHolderToValidator[holder][validatorId]
            .getAndUpdateValueInSequence(month);
        _sendSlashingSignals(slashingSignals);
    }

    /**
     * @dev Allows a token holder to create a delegation proposal of an `amount`
     * and `delegationPeriod` to a `validatorId`. Delegation must be accepted
     * by the validator before the UTC start of the month, otherwise the
     * delegation will be rejected.
     * 
     * The token holder may add additional information in each proposal.
     * 
     * Emits a {DelegationProposed} event.
     * 
     * Requirements:
     * 
     * - Holder must have sufficient delegatable tokens.
     * - Delegation must be above the validator's minimum delegation amount.
     * - Delegation period must be allowed.
     * - Validator must be authorized if trusted list is enabled.
     * - Validator must be accepting new delegation requests.
     */
    function delegate(
        uint validatorId,
        uint amount,
        uint delegationPeriod,
        string calldata info
    )
        external
    {
        require(
            _getDelegationPeriodManager().isDelegationPeriodAllowed(delegationPeriod),
            "This delegation period is not allowed");
        _getValidatorService().checkValidatorCanReceiveDelegation(validatorId, amount);        
        _checkIfDelegationIsAllowed(msg.sender, validatorId);

        SlashingSignal[] memory slashingSignals = _processAllSlashesWithoutSignals(msg.sender);

        uint delegationId = _addDelegation(
            msg.sender,
            validatorId,
            amount,
            delegationPeriod,
            info);

        // check that there is enough money
        uint holderBalance = IERC777(contractManager.getSkaleToken()).balanceOf(msg.sender);
        uint forbiddenForDelegation = TokenState(contractManager.getTokenState())
            .getAndUpdateForbiddenForDelegationAmount(msg.sender);
        require(holderBalance >= forbiddenForDelegation, "Token holder does not have enough tokens to delegate");

        emit DelegationProposed(delegationId);

        _sendSlashingSignals(slashingSignals);
    }

    /**
     * @dev See {ILocker-getAndUpdateLockedAmount}.
     */
    function getAndUpdateLockedAmount(address wallet) external override returns (uint) {
        return _getAndUpdateLockedAmount(wallet);
    }

    /**
     * @dev See {ILocker-getAndUpdateForbiddenForDelegationAmount}.
     */
    function getAndUpdateForbiddenForDelegationAmount(address wallet) external override returns (uint) {
        return _getAndUpdateLockedAmount(wallet);
    }

    /**
     * @dev Allows token holder to cancel a delegation proposal.
     * 
     * Emits a {DelegationRequestCanceledByUser} event.
     * 
     * Requirements:
     * 
     * - `msg.sender` must be the token holder of the delegation proposal.
     * - Delegation state must be PROPOSED.
     */
    function cancelPendingDelegation(uint delegationId) external checkDelegationExists(delegationId) {
        require(msg.sender == delegations[delegationId].holder, "Only token holders can cancel delegation request");
        require(getState(delegationId) == State.PROPOSED, "Token holders are only able to cancel PROPOSED delegations");

        delegations[delegationId].finished = _getCurrentMonth();
        _subtractFromLockedInPendingDelegations(delegations[delegationId].holder, delegations[delegationId].amount);

        emit DelegationRequestCanceledByUser(delegationId);
    }

    /**
     * @dev Allows a validator to accept a proposed delegation.
     * Successful acceptance of delegations transition the tokens from a
     * PROPOSED state to ACCEPTED, and tokens are locked for the remainder of the
     * delegation period.
     * 
     * Emits a {DelegationAccepted} event.
     * 
     * Requirements:
     * 
     * - Validator must be recipient of proposal.
     * - Delegation state must be PROPOSED.
     */
    function acceptPendingDelegation(uint delegationId) external checkDelegationExists(delegationId) {
        require(
            _getValidatorService().checkValidatorAddressToId(msg.sender, delegations[delegationId].validatorId),
            "No permissions to accept request");
        _accept(delegationId);
    }

    /**
     * @dev Allows delegator to undelegate a specific delegation.
     * 
     * Emits UndelegationRequested event.
     * 
     * Requirements:
     * 
     * - `msg.sender` must be the delegator.
     * - Delegation state must be DELEGATED.
     */
    function requestUndelegation(uint delegationId) external checkDelegationExists(delegationId) {
        require(getState(delegationId) == State.DELEGATED, "Cannot request undelegation");
        ValidatorService validatorService = _getValidatorService();
        require(
            delegations[delegationId].holder == msg.sender ||
            (validatorService.validatorAddressExists(msg.sender) &&
            delegations[delegationId].validatorId == validatorService.getValidatorId(msg.sender)),
            "Permission denied to request undelegation");
        _removeValidatorFromValidatorsPerDelegators(
            delegations[delegationId].holder,
            delegations[delegationId].validatorId);
        processAllSlashes(msg.sender);
        delegations[delegationId].finished = _calculateDelegationEndMonth(delegationId);

        require(
            now.add(UNDELEGATION_PROHIBITION_WINDOW_SECONDS)
                < _getTimeHelpers().monthToTimestamp(delegations[delegationId].finished),
            "Undelegation requests must be sent 3 days before the end of delegation period"
        );

        _subtractFromAllStatistics(delegationId);
        
        emit UndelegationRequested(delegationId);
    }

    /**
     * @dev Allows Punisher contract to slash an `amount` of stake from
     * a validator. This slashes an amount of delegations of the validator,
     * which reduces the amount that the validator has staked. This consequence
     * may force the SKALE Manager to reduce the number of nodes a validator is
     * operating so the validator can meet the Minimum Staking Requirement.
     * 
     * Emits a {SlashingEvent}.
     * 
     * See {Punisher}.
     */
    function confiscate(uint validatorId, uint amount) external allow("Punisher") {
        uint currentMonth = _getCurrentMonth();
        FractionUtils.Fraction memory coefficient =
            _delegatedToValidator[validatorId].reduceValue(amount, currentMonth);

        uint initialEffectiveDelegated =
            _effectiveDelegatedToValidator[validatorId].getAndUpdateValueInSequence(currentMonth);
        uint[] memory initialSubtractions = new uint[](0);
        if (currentMonth < _effectiveDelegatedToValidator[validatorId].lastChangedMonth) {
            initialSubtractions = new uint[](
                _effectiveDelegatedToValidator[validatorId].lastChangedMonth.sub(currentMonth)
            );
            for (uint i = 0; i < initialSubtractions.length; ++i) {
                initialSubtractions[i] = _effectiveDelegatedToValidator[validatorId]
                    .subtractDiff[currentMonth.add(i).add(1)];
            }
        }

        _effectiveDelegatedToValidator[validatorId].reduceSequence(coefficient, currentMonth);
        _putToSlashingLog(_slashesOfValidator[validatorId], coefficient, currentMonth);
        _slashes.push(SlashingEvent({reducingCoefficient: coefficient, validatorId: validatorId, month: currentMonth}));

        BountyV2 bounty = _getBounty();
        bounty.handleDelegationRemoving(
            initialEffectiveDelegated.sub(
                _effectiveDelegatedToValidator[validatorId].getAndUpdateValueInSequence(currentMonth)
            ),
            currentMonth
        );
        for (uint i = 0; i < initialSubtractions.length; ++i) {
            bounty.handleDelegationAdd(
                initialSubtractions[i].sub(
                    _effectiveDelegatedToValidator[validatorId].subtractDiff[currentMonth.add(i).add(1)]
                ),
                currentMonth.add(i).add(1)
            );
        }
    }

    /**
     * @dev Allows Distributor contract to return and update the effective 
     * amount delegated (minus slash) to a validator for a given month.
     */
    function getAndUpdateEffectiveDelegatedToValidator(uint validatorId, uint month)
        external allowTwo("Bounty", "Distributor") returns (uint)
    {
        return _effectiveDelegatedToValidator[validatorId].getAndUpdateValueInSequence(month);
    }

    /**
     * @dev Return and update the amount delegated to a validator for the
     * current month.
     */
    function getAndUpdateDelegatedByHolderToValidatorNow(address holder, uint validatorId) external returns (uint) {
        return _getAndUpdateDelegatedByHolderToValidator(holder, validatorId, _getCurrentMonth());
    }

    function getEffectiveDelegatedValuesByValidator(uint validatorId) external view returns (uint[] memory) {
        return _effectiveDelegatedToValidator[validatorId].getValuesInSequence();
    }

    function getEffectiveDelegatedToValidator(uint validatorId, uint month) external view returns (uint) {
        return _effectiveDelegatedToValidator[validatorId].getValueInSequence(month);
    }

    function getDelegatedToValidator(uint validatorId, uint month) external view returns (uint) {
        return _delegatedToValidator[validatorId].getValue(month);
    }

    /**
     * @dev Return Delegation struct.
     */
    function getDelegation(uint delegationId)
        external view checkDelegationExists(delegationId) returns (Delegation memory)
    {
        return delegations[delegationId];
    }

    /**
     * @dev Returns the first delegation month.
     */
    function getFirstDelegationMonth(address holder, uint validatorId) external view returns(uint) {
        return _firstDelegationMonth[holder].byValidator[validatorId];
    }

    /**
     * @dev Returns a validator's total number of delegations.
     */
    function getDelegationsByValidatorLength(uint validatorId) external view returns (uint) {
        return delegationsByValidator[validatorId].length;
    }

    /**
     * @dev Returns a holder's total number of delegations.
     */
    function getDelegationsByHolderLength(address holder) external view returns (uint) {
        return delegationsByHolder[holder].length;
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
    }

    /**
     * @dev Process slashes up to the given limit.
     */
    function processSlashes(address holder, uint limit) public {
        _sendSlashingSignals(_processSlashesWithoutSignals(holder, limit));
    }

    /**
     * @dev Process all slashes.
     */
    function processAllSlashes(address holder) public {
        processSlashes(holder, 0);
    }

    /**
     * @dev Returns the token state of a given delegation.
     */
    function getState(uint delegationId) public view checkDelegationExists(delegationId) returns (State state) {
        if (delegations[delegationId].started == 0) {
            if (delegations[delegationId].finished == 0) {
                if (_getCurrentMonth() == _getTimeHelpers().timestampToMonth(delegations[delegationId].created)) {
                    return State.PROPOSED;
                } else {
                    return State.REJECTED;
                }
            } else {
                return State.CANCELED;
            }
        } else {
            if (_getCurrentMonth() < delegations[delegationId].started) {
                return State.ACCEPTED;
            } else {
                if (delegations[delegationId].finished == 0) {
                    return State.DELEGATED;
                } else {
                    if (_getCurrentMonth() < delegations[delegationId].finished) {
                        return State.UNDELEGATION_REQUESTED;
                    } else {
                        return State.COMPLETED;
                    }
                }
            }
        }
    }

    /**
     * @dev Returns the amount of tokens in PENDING delegation state.
     */
    function getLockedInPendingDelegations(address holder) public view returns (uint) {
        uint currentMonth = _getCurrentMonth();
        if (_lockedInPendingDelegations[holder].month < currentMonth) {
            return 0;
        } else {
            return _lockedInPendingDelegations[holder].amount;
        }
    }

    /**
     * @dev Checks whether there are any unprocessed slashes.
     */
    function hasUnprocessedSlashes(address holder) public view returns (bool) {
        return _everDelegated(holder) && _firstUnprocessedSlashByHolder[holder] < _slashes.length;
    }    

    // private

    /**
     * @dev Allows Nodes contract to get and update the amount delegated
     * to validator for a given month.
     */
    function _getAndUpdateDelegatedToValidator(uint validatorId, uint month)
        private returns (uint)
    {
        return _delegatedToValidator[validatorId].getAndUpdateValue(month);
    }

    /**
     * @dev Adds a new delegation proposal.
     */
    function _addDelegation(
        address holder,
        uint validatorId,
        uint amount,
        uint delegationPeriod,
        string memory info
    )
        private
        returns (uint delegationId)
    {
        delegationId = delegations.length;
        delegations.push(Delegation(
            holder,
            validatorId,
            amount,
            delegationPeriod,
            now,
            0,
            0,
            info
        ));
        delegationsByValidator[validatorId].push(delegationId);
        delegationsByHolder[holder].push(delegationId);
        _addToLockedInPendingDelegations(delegations[delegationId].holder, delegations[delegationId].amount);
    }

    /**
     * @dev Returns the month when a delegation ends.
     */
    function _calculateDelegationEndMonth(uint delegationId) private view returns (uint) {
        uint currentMonth = _getCurrentMonth();
        uint started = delegations[delegationId].started;

        if (currentMonth < started) {
            return started.add(delegations[delegationId].delegationPeriod);
        } else {
            uint completedPeriods = currentMonth.sub(started).div(delegations[delegationId].delegationPeriod);
            return started.add(completedPeriods.add(1).mul(delegations[delegationId].delegationPeriod));
        }
    }

    function _addToDelegatedToValidator(uint validatorId, uint amount, uint month) private {
        _delegatedToValidator[validatorId].addToValue(amount, month);
    }

    function _addToEffectiveDelegatedToValidator(uint validatorId, uint effectiveAmount, uint month) private {
        _effectiveDelegatedToValidator[validatorId].addToSequence(effectiveAmount, month);
    }

    function _addToDelegatedByHolder(address holder, uint amount, uint month) private {
        _delegatedByHolder[holder].addToValue(amount, month);
    }

    function _addToDelegatedByHolderToValidator(
        address holder, uint validatorId, uint amount, uint month) private
    {
        _delegatedByHolderToValidator[holder][validatorId].addToValue(amount, month);
    }

    function _addValidatorToValidatorsPerDelegators(address holder, uint validatorId) private {
        if (_numberOfValidatorsPerDelegator[holder].delegated[validatorId] == 0) {
            _numberOfValidatorsPerDelegator[holder].number = _numberOfValidatorsPerDelegator[holder].number.add(1);
        }
        _numberOfValidatorsPerDelegator[holder].
            delegated[validatorId] = _numberOfValidatorsPerDelegator[holder].delegated[validatorId].add(1);
    }

    function _removeFromDelegatedByHolder(address holder, uint amount, uint month) private {
        _delegatedByHolder[holder].subtractFromValue(amount, month);
    }

    function _removeFromDelegatedByHolderToValidator(
        address holder, uint validatorId, uint amount, uint month) private
    {
        _delegatedByHolderToValidator[holder][validatorId].subtractFromValue(amount, month);
    }

    function _removeValidatorFromValidatorsPerDelegators(address holder, uint validatorId) private {
        if (_numberOfValidatorsPerDelegator[holder].delegated[validatorId] == 1) {
            _numberOfValidatorsPerDelegator[holder].number = _numberOfValidatorsPerDelegator[holder].number.sub(1);
        }
        _numberOfValidatorsPerDelegator[holder].
            delegated[validatorId] = _numberOfValidatorsPerDelegator[holder].delegated[validatorId].sub(1);
    }

    function _addToEffectiveDelegatedByHolderToValidator(
        address holder,
        uint validatorId,
        uint effectiveAmount,
        uint month)
        private
    {
        _effectiveDelegatedByHolderToValidator[holder][validatorId].addToSequence(effectiveAmount, month);
    }

    function _removeFromEffectiveDelegatedByHolderToValidator(
        address holder,
        uint validatorId,
        uint effectiveAmount,
        uint month)
        private
    {
        _effectiveDelegatedByHolderToValidator[holder][validatorId].subtractFromSequence(effectiveAmount, month);
    }

    function _getAndUpdateDelegatedByHolder(address holder) private returns (uint) {
        uint currentMonth = _getCurrentMonth();
        processAllSlashes(holder);
        return _delegatedByHolder[holder].getAndUpdateValue(currentMonth);
    }

    function _getAndUpdateDelegatedByHolderToValidator(
        address holder,
        uint validatorId,
        uint month)
        private returns (uint)
    {
        return _delegatedByHolderToValidator[holder][validatorId].getAndUpdateValue(month);
    }

    function _addToLockedInPendingDelegations(address holder, uint amount) private returns (uint) {
        uint currentMonth = _getCurrentMonth();
        if (_lockedInPendingDelegations[holder].month < currentMonth) {
            _lockedInPendingDelegations[holder].amount = amount;
            _lockedInPendingDelegations[holder].month = currentMonth;
        } else {
            assert(_lockedInPendingDelegations[holder].month == currentMonth);
            _lockedInPendingDelegations[holder].amount = _lockedInPendingDelegations[holder].amount.add(amount);
        }
    }

    function _subtractFromLockedInPendingDelegations(address holder, uint amount) private returns (uint) {
        uint currentMonth = _getCurrentMonth();
        assert(_lockedInPendingDelegations[holder].month == currentMonth);
        _lockedInPendingDelegations[holder].amount = _lockedInPendingDelegations[holder].amount.sub(amount);
    }

    function _getCurrentMonth() private view returns (uint) {
        return _getTimeHelpers().getCurrentMonth();
    }

    /**
     * @dev See {ILocker-getAndUpdateLockedAmount}.
     */
    function _getAndUpdateLockedAmount(address wallet) private returns (uint) {
        return _getAndUpdateDelegatedByHolder(wallet).add(getLockedInPendingDelegations(wallet));
    }

    function _updateFirstDelegationMonth(address holder, uint validatorId, uint month) private {
        if (_firstDelegationMonth[holder].value == 0) {
            _firstDelegationMonth[holder].value = month;
            _firstUnprocessedSlashByHolder[holder] = _slashes.length;
        }
        if (_firstDelegationMonth[holder].byValidator[validatorId] == 0) {
            _firstDelegationMonth[holder].byValidator[validatorId] = month;
        }
    }

    /**
     * @dev Checks whether the holder has performed a delegation.
     */
    function _everDelegated(address holder) private view returns (bool) {
        return _firstDelegationMonth[holder].value > 0;
    }

    function _removeFromDelegatedToValidator(uint validatorId, uint amount, uint month) private {
        _delegatedToValidator[validatorId].subtractFromValue(amount, month);
    }

    function _removeFromEffectiveDelegatedToValidator(uint validatorId, uint effectiveAmount, uint month) private {
        _effectiveDelegatedToValidator[validatorId].subtractFromSequence(effectiveAmount, month);
    }

    /**
     * @dev Returns the delegated amount after a slashing event.
     */
    function _calculateDelegationAmountAfterSlashing(uint delegationId) private view returns (uint) {
        uint startMonth = _delegationExtras[delegationId].lastSlashingMonthBeforeDelegation;
        uint validatorId = delegations[delegationId].validatorId;
        uint amount = delegations[delegationId].amount;
        if (startMonth == 0) {
            startMonth = _slashesOfValidator[validatorId].firstMonth;
            if (startMonth == 0) {
                return amount;
            }
        }
        for (uint i = startMonth;
            i > 0 && i < delegations[delegationId].finished;
            i = _slashesOfValidator[validatorId].slashes[i].nextMonth) {
            if (i >= delegations[delegationId].started) {
                amount = amount
                    .mul(_slashesOfValidator[validatorId].slashes[i].reducingCoefficient.numerator)
                    .div(_slashesOfValidator[validatorId].slashes[i].reducingCoefficient.denominator);
            }
        }
        return amount;
    }

    function _putToSlashingLog(
        SlashingLog storage log,
        FractionUtils.Fraction memory coefficient,
        uint month)
        private
    {
        if (log.firstMonth == 0) {
            log.firstMonth = month;
            log.lastMonth = month;
            log.slashes[month].reducingCoefficient = coefficient;
            log.slashes[month].nextMonth = 0;
        } else {
            require(log.lastMonth <= month, "Cannot put slashing event in the past");
            if (log.lastMonth == month) {
                log.slashes[month].reducingCoefficient =
                    log.slashes[month].reducingCoefficient.multiplyFraction(coefficient);
            } else {
                log.slashes[month].reducingCoefficient = coefficient;
                log.slashes[month].nextMonth = 0;
                log.slashes[log.lastMonth].nextMonth = month;
                log.lastMonth = month;
            }
        }
    }

    function _processSlashesWithoutSignals(address holder, uint limit)
        private returns (SlashingSignal[] memory slashingSignals)
    {
        if (hasUnprocessedSlashes(holder)) {
            uint index = _firstUnprocessedSlashByHolder[holder];
            uint end = _slashes.length;
            if (limit > 0 && index.add(limit) < end) {
                end = index.add(limit);
            }
            slashingSignals = new SlashingSignal[](end.sub(index));
            uint begin = index;
            for (; index < end; ++index) {
                uint validatorId = _slashes[index].validatorId;
                uint month = _slashes[index].month;
                uint oldValue = _getAndUpdateDelegatedByHolderToValidator(holder, validatorId, month);
                if (oldValue.muchGreater(0)) {
                    _delegatedByHolderToValidator[holder][validatorId].reduceValueByCoefficientAndUpdateSum(
                        _delegatedByHolder[holder],
                        _slashes[index].reducingCoefficient,
                        month);
                    _effectiveDelegatedByHolderToValidator[holder][validatorId].reduceSequence(
                        _slashes[index].reducingCoefficient,
                        month);
                    slashingSignals[index.sub(begin)].holder = holder;
                    slashingSignals[index.sub(begin)].penalty
                        = oldValue.boundedSub(_getAndUpdateDelegatedByHolderToValidator(holder, validatorId, month));
                }
            }
            _firstUnprocessedSlashByHolder[holder] = end;
        }
    }

    function _processAllSlashesWithoutSignals(address holder)
        private returns (SlashingSignal[] memory slashingSignals)
    {
        return _processSlashesWithoutSignals(holder, 0);
    }

    function _sendSlashingSignals(SlashingSignal[] memory slashingSignals) private {
        Punisher punisher = Punisher(contractManager.getPunisher());
        address previousHolder = address(0);
        uint accumulatedPenalty = 0;
        for (uint i = 0; i < slashingSignals.length; ++i) {
            if (slashingSignals[i].holder != previousHolder) {
                if (accumulatedPenalty > 0) {
                    punisher.handleSlash(previousHolder, accumulatedPenalty);
                }
                previousHolder = slashingSignals[i].holder;
                accumulatedPenalty = slashingSignals[i].penalty;
            } else {
                accumulatedPenalty = accumulatedPenalty.add(slashingSignals[i].penalty);
            }
        }
        if (accumulatedPenalty > 0) {
            punisher.handleSlash(previousHolder, accumulatedPenalty);
        }
    }

    function _addToAllStatistics(uint delegationId) private {
        uint currentMonth = _getCurrentMonth();
        delegations[delegationId].started = currentMonth.add(1);
        if (_slashesOfValidator[delegations[delegationId].validatorId].lastMonth > 0) {
            _delegationExtras[delegationId].lastSlashingMonthBeforeDelegation =
                _slashesOfValidator[delegations[delegationId].validatorId].lastMonth;
        }

        _addToDelegatedToValidator(
            delegations[delegationId].validatorId,
            delegations[delegationId].amount,
            currentMonth.add(1));
        _addToDelegatedByHolder(
            delegations[delegationId].holder,
            delegations[delegationId].amount,
            currentMonth.add(1));
        _addToDelegatedByHolderToValidator(
            delegations[delegationId].holder,
            delegations[delegationId].validatorId,
            delegations[delegationId].amount,
            currentMonth.add(1));
        _updateFirstDelegationMonth(
            delegations[delegationId].holder,
            delegations[delegationId].validatorId,
            currentMonth.add(1));
        uint effectiveAmount = delegations[delegationId].amount.mul(
            _getDelegationPeriodManager().stakeMultipliers(delegations[delegationId].delegationPeriod));
        _addToEffectiveDelegatedToValidator(
            delegations[delegationId].validatorId,
            effectiveAmount,
            currentMonth.add(1));
        _addToEffectiveDelegatedByHolderToValidator(
            delegations[delegationId].holder,
            delegations[delegationId].validatorId,
            effectiveAmount,
            currentMonth.add(1));
        _addValidatorToValidatorsPerDelegators(
            delegations[delegationId].holder,
            delegations[delegationId].validatorId
        );
    }

    function _subtractFromAllStatistics(uint delegationId) private {
        uint amountAfterSlashing = _calculateDelegationAmountAfterSlashing(delegationId);
        _removeFromDelegatedToValidator(
            delegations[delegationId].validatorId,
            amountAfterSlashing,
            delegations[delegationId].finished);
        _removeFromDelegatedByHolder(
            delegations[delegationId].holder,
            amountAfterSlashing,
            delegations[delegationId].finished);
        _removeFromDelegatedByHolderToValidator(
            delegations[delegationId].holder,
            delegations[delegationId].validatorId,
            amountAfterSlashing,
            delegations[delegationId].finished);
        uint effectiveAmount = amountAfterSlashing.mul(
                _getDelegationPeriodManager().stakeMultipliers(delegations[delegationId].delegationPeriod));
        _removeFromEffectiveDelegatedToValidator(
            delegations[delegationId].validatorId,
            effectiveAmount,
            delegations[delegationId].finished);
        _removeFromEffectiveDelegatedByHolderToValidator(
            delegations[delegationId].holder,
            delegations[delegationId].validatorId,
            effectiveAmount,
            delegations[delegationId].finished);
        _getBounty().handleDelegationRemoving(
            effectiveAmount,
            delegations[delegationId].finished);
    }

    /**
     * @dev Checks whether delegation to a validator is allowed.
     * 
     * Requirements:
     * 
     * - Delegator must not have reached the validator limit.
     * - Delegation must be made in or after the first delegation month.
     */
    function _checkIfDelegationIsAllowed(address holder, uint validatorId) private view returns (bool) {
        require(
            _numberOfValidatorsPerDelegator[holder].delegated[validatorId] > 0 ||
                (
                    _numberOfValidatorsPerDelegator[holder].delegated[validatorId] == 0 &&
                    _numberOfValidatorsPerDelegator[holder].number < _getConstantsHolder().limitValidatorsPerDelegator()
                ),
            "Limit of validators is reached"
        );
    }

    function _getDelegationPeriodManager() private view returns (DelegationPeriodManager) {
        return DelegationPeriodManager(contractManager.getDelegationPeriodManager());
    }

    function _getBounty() private view returns (BountyV2) {
        return BountyV2(contractManager.getBounty());
    }

    function _getValidatorService() private view returns (ValidatorService) {
        return ValidatorService(contractManager.getValidatorService());
    }

    function _getTimeHelpers() private view returns (TimeHelpers) {
        return TimeHelpers(contractManager.getTimeHelpers());
    }

    function _getConstantsHolder() private view returns (ConstantsHolder) {
        return ConstantsHolder(contractManager.getConstantsHolder());
    }

    function _accept(uint delegationId) private {
        _checkIfDelegationIsAllowed(delegations[delegationId].holder, delegations[delegationId].validatorId);
        
        State currentState = getState(delegationId);
        if (currentState != State.PROPOSED) {
            if (currentState == State.ACCEPTED ||
                currentState == State.DELEGATED ||
                currentState == State.UNDELEGATION_REQUESTED ||
                currentState == State.COMPLETED)
            {
                revert("The delegation has been already accepted");
            } else if (currentState == State.CANCELED) {
                revert("The delegation has been cancelled by token holder");
            } else if (currentState == State.REJECTED) {
                revert("The delegation request is outdated");
            }
        }
        require(currentState == State.PROPOSED, "Cannot set delegation state to accepted");

        SlashingSignal[] memory slashingSignals = _processAllSlashesWithoutSignals(delegations[delegationId].holder);

        _addToAllStatistics(delegationId);
        
        uint amount = delegations[delegationId].amount;

        uint effectiveAmount = amount.mul(
            _getDelegationPeriodManager().stakeMultipliers(delegations[delegationId].delegationPeriod)
        );
        _getBounty().handleDelegationAdd(
            effectiveAmount,
            delegations[delegationId].started
        );

        _sendSlashingSignals(slashingSignals);
        emit DelegationAccepted(delegationId);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    PartialDifferences.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "../utils/MathUtils.sol";
import "../utils/FractionUtils.sol";

/**
 * @title Partial Differences Library
 * @dev This library contains functions to manage Partial Differences data
 * structure. Partial Differences is an array of value differences over time.
 * 
 * For example: assuming an array [3, 6, 3, 1, 2], partial differences can
 * represent this array as [_, 3, -3, -2, 1].
 * 
 * This data structure allows adding values on an open interval with O(1)
 * complexity.
 * 
 * For example: add +5 to [3, 6, 3, 1, 2] starting from the second element (3),
 * instead of performing [3, 6, 3+5, 1+5, 2+5] partial differences allows
 * performing [_, 3, -3+5, -2, 1]. The original array can be restored by
 * adding values from partial differences.
 */
library PartialDifferences {
    using SafeMath for uint;
    using MathUtils for uint;

    struct Sequence {
             // month => diff
        mapping (uint => uint) addDiff;
             // month => diff
        mapping (uint => uint) subtractDiff;
             // month => value
        mapping (uint => uint) value;

        uint firstUnprocessedMonth;
        uint lastChangedMonth;
    }

    struct Value {
             // month => diff
        mapping (uint => uint) addDiff;
             // month => diff
        mapping (uint => uint) subtractDiff;

        uint value;
        uint firstUnprocessedMonth;
        uint lastChangedMonth;
    }

    // functions for sequence

    function addToSequence(Sequence storage sequence, uint diff, uint month) internal {
        require(sequence.firstUnprocessedMonth <= month, "Cannot add to the past");
        if (sequence.firstUnprocessedMonth == 0) {
            sequence.firstUnprocessedMonth = month;
        }
        sequence.addDiff[month] = sequence.addDiff[month].add(diff);
        if (sequence.lastChangedMonth != month) {
            sequence.lastChangedMonth = month;
        }
    }

    function subtractFromSequence(Sequence storage sequence, uint diff, uint month) internal {
        require(sequence.firstUnprocessedMonth <= month, "Cannot subtract from the past");
        if (sequence.firstUnprocessedMonth == 0) {
            sequence.firstUnprocessedMonth = month;
        }
        sequence.subtractDiff[month] = sequence.subtractDiff[month].add(diff);
        if (sequence.lastChangedMonth != month) {
            sequence.lastChangedMonth = month;
        }
    }

    function getAndUpdateValueInSequence(Sequence storage sequence, uint month) internal returns (uint) {
        if (sequence.firstUnprocessedMonth == 0) {
            return 0;
        }

        if (sequence.firstUnprocessedMonth <= month) {
            for (uint i = sequence.firstUnprocessedMonth; i <= month; ++i) {
                uint nextValue = sequence.value[i.sub(1)].add(sequence.addDiff[i]).boundedSub(sequence.subtractDiff[i]);
                if (sequence.value[i] != nextValue) {
                    sequence.value[i] = nextValue;
                }
                if (sequence.addDiff[i] > 0) {
                    delete sequence.addDiff[i];
                }
                if (sequence.subtractDiff[i] > 0) {
                    delete sequence.subtractDiff[i];
                }
            }
            sequence.firstUnprocessedMonth = month.add(1);
        }

        return sequence.value[month];
    }

    function getValueInSequence(Sequence storage sequence, uint month) internal view returns (uint) {
        if (sequence.firstUnprocessedMonth == 0) {
            return 0;
        }

        if (sequence.firstUnprocessedMonth <= month) {
            uint value = sequence.value[sequence.firstUnprocessedMonth.sub(1)];
            for (uint i = sequence.firstUnprocessedMonth; i <= month; ++i) {
                value = value.add(sequence.addDiff[i]).sub(sequence.subtractDiff[i]);
            }
            return value;
        } else {
            return sequence.value[month];
        }
    }

    function getValuesInSequence(Sequence storage sequence) internal view returns (uint[] memory values) {
        if (sequence.firstUnprocessedMonth == 0) {
            return values;
        }
        uint begin = sequence.firstUnprocessedMonth.sub(1);
        uint end = sequence.lastChangedMonth.add(1);
        if (end <= begin) {
            end = begin.add(1);
        }
        values = new uint[](end.sub(begin));
        values[0] = sequence.value[sequence.firstUnprocessedMonth.sub(1)];
        for (uint i = 0; i.add(1) < values.length; ++i) {
            uint month = sequence.firstUnprocessedMonth.add(i);
            values[i.add(1)] = values[i].add(sequence.addDiff[month]).sub(sequence.subtractDiff[month]);
        }
    }

    function reduceSequence(
        Sequence storage sequence,
        FractionUtils.Fraction memory reducingCoefficient,
        uint month) internal
    {
        require(month.add(1) >= sequence.firstUnprocessedMonth, "Cannot reduce value in the past");
        require(
            reducingCoefficient.numerator <= reducingCoefficient.denominator,
            "Increasing of values is not implemented");
        if (sequence.firstUnprocessedMonth == 0) {
            return;
        }
        uint value = getAndUpdateValueInSequence(sequence, month);
        if (value.approximatelyEqual(0)) {
            return;
        }

        sequence.value[month] = sequence.value[month]
            .mul(reducingCoefficient.numerator)
            .div(reducingCoefficient.denominator);

        for (uint i = month.add(1); i <= sequence.lastChangedMonth; ++i) {
            sequence.subtractDiff[i] = sequence.subtractDiff[i]
                .mul(reducingCoefficient.numerator)
                .div(reducingCoefficient.denominator);
        }
    }

    // functions for value

    function addToValue(Value storage sequence, uint diff, uint month) internal {
        require(sequence.firstUnprocessedMonth <= month, "Cannot add to the past");
        if (sequence.firstUnprocessedMonth == 0) {
            sequence.firstUnprocessedMonth = month;
            sequence.lastChangedMonth = month;
        }
        if (month > sequence.lastChangedMonth) {
            sequence.lastChangedMonth = month;
        }

        if (month >= sequence.firstUnprocessedMonth) {
            sequence.addDiff[month] = sequence.addDiff[month].add(diff);
        } else {
            sequence.value = sequence.value.add(diff);
        }
    }

    function subtractFromValue(Value storage sequence, uint diff, uint month) internal {
        require(sequence.firstUnprocessedMonth <= month.add(1), "Cannot subtract from the past");
        if (sequence.firstUnprocessedMonth == 0) {
            sequence.firstUnprocessedMonth = month;
            sequence.lastChangedMonth = month;
        }
        if (month > sequence.lastChangedMonth) {
            sequence.lastChangedMonth = month;
        }

        if (month >= sequence.firstUnprocessedMonth) {
            sequence.subtractDiff[month] = sequence.subtractDiff[month].add(diff);
        } else {
            sequence.value = sequence.value.boundedSub(diff);
        }
    }

    function getAndUpdateValue(Value storage sequence, uint month) internal returns (uint) {
        require(
            month.add(1) >= sequence.firstUnprocessedMonth,
            "Cannot calculate value in the past");
        if (sequence.firstUnprocessedMonth == 0) {
            return 0;
        }

        if (sequence.firstUnprocessedMonth <= month) {
            uint value = sequence.value;
            for (uint i = sequence.firstUnprocessedMonth; i <= month; ++i) {
                value = value.add(sequence.addDiff[i]).boundedSub(sequence.subtractDiff[i]);
                if (sequence.addDiff[i] > 0) {
                    delete sequence.addDiff[i];
                }
                if (sequence.subtractDiff[i] > 0) {
                    delete sequence.subtractDiff[i];
                }
            }
            if (sequence.value != value) {
                sequence.value = value;
            }
            sequence.firstUnprocessedMonth = month.add(1);
        }

        return sequence.value;
    }

    function getValue(Value storage sequence, uint month) internal view returns (uint) {
        require(
            month.add(1) >= sequence.firstUnprocessedMonth,
            "Cannot calculate value in the past");
        if (sequence.firstUnprocessedMonth == 0) {
            return 0;
        }

        if (sequence.firstUnprocessedMonth <= month) {
            uint value = sequence.value;
            for (uint i = sequence.firstUnprocessedMonth; i <= month; ++i) {
                value = value.add(sequence.addDiff[i]).sub(sequence.subtractDiff[i]);
            }
            return value;
        } else {
            return sequence.value;
        }
    }

    function getValues(Value storage sequence) internal view returns (uint[] memory values) {
        if (sequence.firstUnprocessedMonth == 0) {
            return values;
        }
        uint begin = sequence.firstUnprocessedMonth.sub(1);
        uint end = sequence.lastChangedMonth.add(1);
        if (end <= begin) {
            end = begin.add(1);
        }
        values = new uint[](end.sub(begin));
        values[0] = sequence.value;
        for (uint i = 0; i.add(1) < values.length; ++i) {
            uint month = sequence.firstUnprocessedMonth.add(i);
            values[i.add(1)] = values[i].add(sequence.addDiff[month]).sub(sequence.subtractDiff[month]);
        }
    }

    function reduceValue(
        Value storage sequence,
        uint amount,
        uint month)
        internal returns (FractionUtils.Fraction memory)
    {
        require(month.add(1) >= sequence.firstUnprocessedMonth, "Cannot reduce value in the past");
        if (sequence.firstUnprocessedMonth == 0) {
            return FractionUtils.createFraction(0);
        }
        uint value = getAndUpdateValue(sequence, month);
        if (value.approximatelyEqual(0)) {
            return FractionUtils.createFraction(0);
        }

        uint _amount = amount;
        if (value < amount) {
            _amount = value;
        }

        FractionUtils.Fraction memory reducingCoefficient =
            FractionUtils.createFraction(value.boundedSub(_amount), value);
        reduceValueByCoefficient(sequence, reducingCoefficient, month);
        return reducingCoefficient;
    }

    function reduceValueByCoefficient(
        Value storage sequence,
        FractionUtils.Fraction memory reducingCoefficient,
        uint month)
        internal
    {
        reduceValueByCoefficientAndUpdateSumIfNeeded(
            sequence,
            sequence,
            reducingCoefficient,
            month,
            false);
    }

    function reduceValueByCoefficientAndUpdateSum(
        Value storage sequence,
        Value storage sumSequence,
        FractionUtils.Fraction memory reducingCoefficient,
        uint month) internal
    {
        reduceValueByCoefficientAndUpdateSumIfNeeded(
            sequence,
            sumSequence,
            reducingCoefficient,
            month,
            true);
    }

    function reduceValueByCoefficientAndUpdateSumIfNeeded(
        Value storage sequence,
        Value storage sumSequence,
        FractionUtils.Fraction memory reducingCoefficient,
        uint month,
        bool hasSumSequence) internal
    {
        require(month.add(1) >= sequence.firstUnprocessedMonth, "Cannot reduce value in the past");
        if (hasSumSequence) {
            require(month.add(1) >= sumSequence.firstUnprocessedMonth, "Cannot reduce value in the past");
        }
        require(
            reducingCoefficient.numerator <= reducingCoefficient.denominator,
            "Increasing of values is not implemented");
        if (sequence.firstUnprocessedMonth == 0) {
            return;
        }
        uint value = getAndUpdateValue(sequence, month);
        if (value.approximatelyEqual(0)) {
            return;
        }

        uint newValue = sequence.value.mul(reducingCoefficient.numerator).div(reducingCoefficient.denominator);
        if (hasSumSequence) {
            subtractFromValue(sumSequence, sequence.value.boundedSub(newValue), month);
        }
        sequence.value = newValue;

        for (uint i = month.add(1); i <= sequence.lastChangedMonth; ++i) {
            uint newDiff = sequence.subtractDiff[i]
                .mul(reducingCoefficient.numerator)
                .div(reducingCoefficient.denominator);
            if (hasSumSequence) {
                sumSequence.subtractDiff[i] = sumSequence.subtractDiff[i]
                    .boundedSub(sequence.subtractDiff[i].boundedSub(newDiff));
            }
            sequence.subtractDiff[i] = newDiff;
        }
    }

    function clear(Value storage sequence) internal {
        for (uint i = sequence.firstUnprocessedMonth; i <= sequence.lastChangedMonth; ++i) {
            if (sequence.addDiff[i] > 0) {
                delete sequence.addDiff[i];
            }
            if (sequence.subtractDiff[i] > 0) {
                delete sequence.subtractDiff[i];
            }
        }
        if (sequence.value > 0) {
            delete sequence.value;
        }
        if (sequence.firstUnprocessedMonth > 0) {
            delete sequence.firstUnprocessedMonth;
        }
        if (sequence.lastChangedMonth > 0) {
            delete sequence.lastChangedMonth;
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    TimeHelpers.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

import "../thirdparty/BokkyPooBahsDateTimeLibrary.sol";

/**
 * @title TimeHelpers
 * @dev The contract performs time operations.
 * 
 * These functions are used to calculate monthly and Proof of Use epochs.
 */
contract TimeHelpers {
    using SafeMath for uint;

    uint constant private _ZERO_YEAR = 2020;

    function calculateProofOfUseLockEndTime(uint month, uint lockUpPeriodDays) external view returns (uint timestamp) {
        timestamp = BokkyPooBahsDateTimeLibrary.addDays(monthToTimestamp(month), lockUpPeriodDays);
    }

    function addDays(uint fromTimestamp, uint n) external pure returns (uint) {
        return BokkyPooBahsDateTimeLibrary.addDays(fromTimestamp, n);
    }

    function addMonths(uint fromTimestamp, uint n) external pure returns (uint) {
        return BokkyPooBahsDateTimeLibrary.addMonths(fromTimestamp, n);
    }

    function addYears(uint fromTimestamp, uint n) external pure returns (uint) {
        return BokkyPooBahsDateTimeLibrary.addYears(fromTimestamp, n);
    }

    function getCurrentMonth() external view virtual returns (uint) {
        return timestampToMonth(now);
    }

    function timestampToDay(uint timestamp) external view returns (uint) {
        uint wholeDays = timestamp / BokkyPooBahsDateTimeLibrary.SECONDS_PER_DAY;
        uint zeroDay = BokkyPooBahsDateTimeLibrary.timestampFromDate(_ZERO_YEAR, 1, 1) /
            BokkyPooBahsDateTimeLibrary.SECONDS_PER_DAY;
        require(wholeDays >= zeroDay, "Timestamp is too far in the past");
        return wholeDays - zeroDay;
    }

    function timestampToYear(uint timestamp) external view virtual returns (uint) {
        uint year;
        (year, , ) = BokkyPooBahsDateTimeLibrary.timestampToDate(timestamp);
        require(year >= _ZERO_YEAR, "Timestamp is too far in the past");
        return year - _ZERO_YEAR;
    }

    function timestampToMonth(uint timestamp) public view virtual returns (uint) {
        uint year;
        uint month;
        (year, month, ) = BokkyPooBahsDateTimeLibrary.timestampToDate(timestamp);
        require(year >= _ZERO_YEAR, "Timestamp is too far in the past");
        month = month.sub(1).add(year.sub(_ZERO_YEAR).mul(12));
        require(month > 0, "Timestamp is too far in the past");
        return month;
    }

    function monthToTimestamp(uint month) public view virtual returns (uint timestamp) {
        uint year = _ZERO_YEAR;
        uint _month = month;
        year = year.add(_month.div(12));
        _month = _month.mod(12);
        _month = _month.add(1);
        return BokkyPooBahsDateTimeLibrary.timestampFromDate(year, _month, 1);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    ValidatorService.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/cryptography/ECDSA.sol";

import "../Permissions.sol";
import "../ConstantsHolder.sol";

import "./DelegationController.sol";
import "./TimeHelpers.sol";

/**
 * @title ValidatorService
 * @dev This contract handles all validator operations including registration,
 * node management, validator-specific delegation parameters, and more.
 * 
 * TIP: For more information see our main instructions
 * https://forum.skale.network/t/skale-mainnet-launch-faq/182[SKALE MainNet Launch FAQ].
 * 
 * Validators register an address, and use this address to accept delegations and
 * register nodes.
 */
contract ValidatorService is Permissions {

    using ECDSA for bytes32;

    struct Validator {
        string name;
        address validatorAddress;
        address requestedAddress;
        string description;
        uint feeRate;
        uint registrationTime;
        uint minimumDelegationAmount;
        bool acceptNewRequests;
    }

    /**
     * @dev Emitted when a validator registers.
     */
    event ValidatorRegistered(
        uint validatorId
    );

    /**
     * @dev Emitted when a validator address changes.
     */
    event ValidatorAddressChanged(
        uint validatorId,
        address newAddress
    );

    /**
     * @dev Emitted when a validator is enabled.
     */
    event ValidatorWasEnabled(
        uint validatorId
    );

    /**
     * @dev Emitted when a validator is disabled.
     */
    event ValidatorWasDisabled(
        uint validatorId
    );

    /**
     * @dev Emitted when a node address is linked to a validator.
     */
    event NodeAddressWasAdded(
        uint validatorId,
        address nodeAddress
    );

    /**
     * @dev Emitted when a node address is unlinked from a validator.
     */
    event NodeAddressWasRemoved(
        uint validatorId,
        address nodeAddress
    );

    mapping (uint => Validator) public validators;
    mapping (uint => bool) private _trustedValidators;
    uint[] public trustedValidatorsList;
    //       address => validatorId
    mapping (address => uint) private _validatorAddressToId;
    //       address => validatorId
    mapping (address => uint) private _nodeAddressToValidatorId;
    // validatorId => nodeAddress[]
    mapping (uint => address[]) private _nodeAddresses;
    uint public numberOfValidators;
    bool public useWhitelist;

    modifier checkValidatorExists(uint validatorId) {
        require(validatorExists(validatorId), "Validator with such ID does not exist");
        _;
    }

    /**
     * @dev Creates a new validator ID that includes a validator name, description,
     * commission or fee rate, and a minimum delegation amount accepted by the validator.
     * 
     * Emits a {ValidatorRegistered} event.
     * 
     * Requirements:
     * 
     * - Sender must not already have registered a validator ID.
     * - Fee rate must be between 0 - 1000‰. Note: in per mille.
     */
    function registerValidator(
        string calldata name,
        string calldata description,
        uint feeRate,
        uint minimumDelegationAmount
    )
        external
        returns (uint validatorId)
    {
        require(!validatorAddressExists(msg.sender), "Validator with such address already exists");
        require(feeRate <= 1000, "Fee rate of validator should be lower than 100%");
        validatorId = ++numberOfValidators;
        validators[validatorId] = Validator(
            name,
            msg.sender,
            address(0),
            description,
            feeRate,
            now,
            minimumDelegationAmount,
            true
        );
        _setValidatorAddress(validatorId, msg.sender);

        emit ValidatorRegistered(validatorId);
    }

    /**
     * @dev Allows Admin to enable a validator by adding their ID to the
     * trusted list.
     * 
     * Emits a {ValidatorWasEnabled} event.
     * 
     * Requirements:
     * 
     * - Validator must not already be enabled.
     */
    function enableValidator(uint validatorId) external checkValidatorExists(validatorId) onlyAdmin {
        require(!_trustedValidators[validatorId], "Validator is already enabled");
        _trustedValidators[validatorId] = true;
        trustedValidatorsList.push(validatorId);
        emit ValidatorWasEnabled(validatorId);
    }

    /**
     * @dev Allows Admin to disable a validator by removing their ID from
     * the trusted list.
     * 
     * Emits a {ValidatorWasDisabled} event.
     * 
     * Requirements:
     * 
     * - Validator must not already be disabled.
     */
    function disableValidator(uint validatorId) external checkValidatorExists(validatorId) onlyAdmin {
        require(_trustedValidators[validatorId], "Validator is already disabled");
        _trustedValidators[validatorId] = false;
        uint position = _find(trustedValidatorsList, validatorId);
        if (position < trustedValidatorsList.length) {
            trustedValidatorsList[position] =
                trustedValidatorsList[trustedValidatorsList.length.sub(1)];
        }
        trustedValidatorsList.pop();
        emit ValidatorWasDisabled(validatorId);
    }

    /**
     * @dev Owner can disable the trusted validator list. Once turned off, the
     * trusted list cannot be re-enabled.
     */
    function disableWhitelist() external onlyOwner {
        useWhitelist = false;
    }

    /**
     * @dev Allows `msg.sender` to request a new address.
     * 
     * Requirements:
     *
     * - `msg.sender` must already be a validator.
     * - New address must not be null.
     * - New address must not be already registered as a validator.
     */
    function requestForNewAddress(address newValidatorAddress) external {
        require(newValidatorAddress != address(0), "New address cannot be null");
        require(_validatorAddressToId[newValidatorAddress] == 0, "Address already registered");
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);

        validators[validatorId].requestedAddress = newValidatorAddress;
    }

    /**
     * @dev Allows msg.sender to confirm an address change.
     * 
     * Emits a {ValidatorAddressChanged} event.
     * 
     * Requirements:
     * 
     * - Must be owner of new address.
     */
    function confirmNewAddress(uint validatorId)
        external
        checkValidatorExists(validatorId)
    {
        require(
            getValidator(validatorId).requestedAddress == msg.sender,
            "The validator address cannot be changed because it is not the actual owner"
        );
        delete validators[validatorId].requestedAddress;
        _setValidatorAddress(validatorId, msg.sender);

        emit ValidatorAddressChanged(validatorId, validators[validatorId].validatorAddress);
    }

    /**
     * @dev Links a node address to validator ID. Validator must present
     * the node signature of the validator ID.
     * 
     * Requirements:
     * 
     * - Signature must be valid.
     * - Address must not be assigned to a validator.
     */
    function linkNodeAddress(address nodeAddress, bytes calldata sig) external {
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);
        require(
            keccak256(abi.encodePacked(validatorId)).toEthSignedMessageHash().recover(sig) == nodeAddress,
            "Signature is not pass"
        );
        require(_validatorAddressToId[nodeAddress] == 0, "Node address is a validator");

        _addNodeAddress(validatorId, nodeAddress);
        emit NodeAddressWasAdded(validatorId, nodeAddress);
    }

    /**
     * @dev Unlinks a node address from a validator.
     * 
     * Emits a {NodeAddressWasRemoved} event.
     */
    function unlinkNodeAddress(address nodeAddress) external {
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);

        this.removeNodeAddress(validatorId, nodeAddress);
        emit NodeAddressWasRemoved(validatorId, nodeAddress);
    }

    /**
     * @dev Allows a validator to set a minimum delegation amount.
     */
    function setValidatorMDA(uint minimumDelegationAmount) external {
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);

        validators[validatorId].minimumDelegationAmount = minimumDelegationAmount;
    }

    /**
     * @dev Allows a validator to set a new validator name.
     */
    function setValidatorName(string calldata newName) external {
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);

        validators[validatorId].name = newName;
    }

    /**
     * @dev Allows a validator to set a new validator description.
     */
    function setValidatorDescription(string calldata newDescription) external {
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);

        validators[validatorId].description = newDescription;
    }

    /**
     * @dev Allows a validator to start accepting new delegation requests.
     * 
     * Requirements:
     * 
     * - Must not have already enabled accepting new requests.
     */
    function startAcceptingNewRequests() external {
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);
        require(!isAcceptingNewRequests(validatorId), "Accepting request is already enabled");

        validators[validatorId].acceptNewRequests = true;
    }

    /**
     * @dev Allows a validator to stop accepting new delegation requests.
     * 
     * Requirements:
     * 
     * - Must not have already stopped accepting new requests.
     */
    function stopAcceptingNewRequests() external {
        // check Validator Exist inside getValidatorId
        uint validatorId = getValidatorId(msg.sender);
        require(isAcceptingNewRequests(validatorId), "Accepting request is already disabled");

        validators[validatorId].acceptNewRequests = false;
    }

    function removeNodeAddress(uint validatorId, address nodeAddress) external allowTwo("ValidatorService", "Nodes") {
        require(_nodeAddressToValidatorId[nodeAddress] == validatorId,
            "Validator does not have permissions to unlink node");
        delete _nodeAddressToValidatorId[nodeAddress];
        for (uint i = 0; i < _nodeAddresses[validatorId].length; ++i) {
            if (_nodeAddresses[validatorId][i] == nodeAddress) {
                if (i + 1 < _nodeAddresses[validatorId].length) {
                    _nodeAddresses[validatorId][i] =
                        _nodeAddresses[validatorId][_nodeAddresses[validatorId].length.sub(1)];
                }
                delete _nodeAddresses[validatorId][_nodeAddresses[validatorId].length.sub(1)];
                _nodeAddresses[validatorId].pop();
                break;
            }
        }
    }

    /**
     * @dev Returns the amount of validator bond (self-delegation).
     */
    function getAndUpdateBondAmount(uint validatorId)
        external
        returns (uint)
    {
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        return delegationController.getAndUpdateDelegatedByHolderToValidatorNow(
            getValidator(validatorId).validatorAddress,
            validatorId
        );
    }

    /**
     * @dev Returns node addresses linked to the msg.sender.
     */
    function getMyNodesAddresses() external view returns (address[] memory) {
        return getNodeAddresses(getValidatorId(msg.sender));
    }

    /**
     * @dev Returns the list of trusted validators.
     */
    function getTrustedValidators() external view returns (uint[] memory) {
        return trustedValidatorsList;
    }

    /**
     * @dev Checks whether the validator ID is linked to the validator address.
     */
    function checkValidatorAddressToId(address validatorAddress, uint validatorId)
        external
        view
        returns (bool)
    {
        return getValidatorId(validatorAddress) == validatorId ? true : false;
    }

    /**
     * @dev Returns the validator ID linked to a node address.
     * 
     * Requirements:
     * 
     * - Node address must be linked to a validator.
     */
    function getValidatorIdByNodeAddress(address nodeAddress) external view returns (uint validatorId) {
        validatorId = _nodeAddressToValidatorId[nodeAddress];
        require(validatorId != 0, "Node address is not assigned to a validator");
    }

    function checkValidatorCanReceiveDelegation(uint validatorId, uint amount) external view {
        require(isAuthorizedValidator(validatorId), "Validator is not authorized to accept delegation request");
        require(isAcceptingNewRequests(validatorId), "The validator is not currently accepting new requests");
        require(
            validators[validatorId].minimumDelegationAmount <= amount,
            "Amount does not meet the validator's minimum delegation amount"
        );
    }

    function initialize(address contractManagerAddress) public override initializer {
        Permissions.initialize(contractManagerAddress);
        useWhitelist = true;
    }

    /**
     * @dev Returns a validator's node addresses.
     */
    function getNodeAddresses(uint validatorId) public view returns (address[] memory) {
        return _nodeAddresses[validatorId];
    }

    /**
     * @dev Checks whether validator ID exists.
     */
    function validatorExists(uint validatorId) public view returns (bool) {
        return validatorId <= numberOfValidators && validatorId != 0;
    }

    /**
     * @dev Checks whether validator address exists.
     */
    function validatorAddressExists(address validatorAddress) public view returns (bool) {
        return _validatorAddressToId[validatorAddress] != 0;
    }

    /**
     * @dev Checks whether validator address exists.
     */
    function checkIfValidatorAddressExists(address validatorAddress) public view {
        require(validatorAddressExists(validatorAddress), "Validator address does not exist");
    }

    /**
     * @dev Returns the Validator struct.
     */
    function getValidator(uint validatorId) public view checkValidatorExists(validatorId) returns (Validator memory) {
        return validators[validatorId];
    }

    /**
     * @dev Returns the validator ID for the given validator address.
     */
    function getValidatorId(address validatorAddress) public view returns (uint) {
        checkIfValidatorAddressExists(validatorAddress);
        return _validatorAddressToId[validatorAddress];
    }

    /**
     * @dev Checks whether the validator is currently accepting new delegation requests.
     */
    function isAcceptingNewRequests(uint validatorId) public view checkValidatorExists(validatorId) returns (bool) {
        return validators[validatorId].acceptNewRequests;
    }

    function isAuthorizedValidator(uint validatorId) public view checkValidatorExists(validatorId) returns (bool) {
        return _trustedValidators[validatorId] || !useWhitelist;
    }

    // private

    /**
     * @dev Links a validator address to a validator ID.
     * 
     * Requirements:
     * 
     * - Address is not already in use by another validator.
     */
    function _setValidatorAddress(uint validatorId, address validatorAddress) private {
        if (_validatorAddressToId[validatorAddress] == validatorId) {
            return;
        }
        require(_validatorAddressToId[validatorAddress] == 0, "Address is in use by another validator");
        address oldAddress = validators[validatorId].validatorAddress;
        delete _validatorAddressToId[oldAddress];
        _nodeAddressToValidatorId[validatorAddress] = validatorId;
        validators[validatorId].validatorAddress = validatorAddress;
        _validatorAddressToId[validatorAddress] = validatorId;
    }

    /**
     * @dev Links a node address to a validator ID.
     * 
     * Requirements:
     * 
     * - Node address must not be already linked to a validator.
     */
    function _addNodeAddress(uint validatorId, address nodeAddress) private {
        if (_nodeAddressToValidatorId[nodeAddress] == validatorId) {
            return;
        }
        require(_nodeAddressToValidatorId[nodeAddress] == 0, "Validator cannot override node address");
        _nodeAddressToValidatorId[nodeAddress] = validatorId;
        _nodeAddresses[validatorId].push(nodeAddress);
    }

    function _find(uint[] memory array, uint index) private pure returns (uint) {
        uint i;
        for (i = 0; i < array.length; i++) {
            if (array[i] == index) {
                return i;
            }
        }
        return array.length;
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    ConstantsHolder.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "./Permissions.sol";


/**
 * @title ConstantsHolder
 * @dev Contract contains constants and common variables for the SKALE Network.
 */
contract ConstantsHolder is Permissions {

    // initial price for creating Node (100 SKL)
    uint public constant NODE_DEPOSIT = 100 * 1e18;

    uint8 public constant TOTAL_SPACE_ON_NODE = 128;

    // part of Node for Small Skale-chain (1/128 of Node)
    uint8 public constant SMALL_DIVISOR = 128;

    // part of Node for Medium Skale-chain (1/32 of Node)
    uint8 public constant MEDIUM_DIVISOR = 32;

    // part of Node for Large Skale-chain (full Node)
    uint8 public constant LARGE_DIVISOR = 1;

    // part of Node for Medium Test Skale-chain (1/4 of Node)
    uint8 public constant MEDIUM_TEST_DIVISOR = 4;

    // typically number of Nodes for Skale-chain (16 Nodes)
    uint public constant NUMBER_OF_NODES_FOR_SCHAIN = 16;

    // number of Nodes for Test Skale-chain (2 Nodes)
    uint public constant NUMBER_OF_NODES_FOR_TEST_SCHAIN = 2;

    // number of Nodes for Test Skale-chain (4 Nodes)
    uint public constant NUMBER_OF_NODES_FOR_MEDIUM_TEST_SCHAIN = 4;    

    // number of seconds in one year
    uint32 public constant SECONDS_TO_YEAR = 31622400;

    // initial number of monitors
    uint public constant NUMBER_OF_MONITORS = 24;

    uint public constant OPTIMAL_LOAD_PERCENTAGE = 80;

    uint public constant ADJUSTMENT_SPEED = 1000;

    uint public constant COOLDOWN_TIME = 60;

    uint public constant MIN_PRICE = 10**6;

    uint public constant MSR_REDUCING_COEFFICIENT = 2;

    uint public constant DOWNTIME_THRESHOLD_PART = 30;

    uint public constant BOUNTY_LOCKUP_MONTHS = 2;

    uint public constant ALRIGHT_DELTA = 54640;
    uint public constant BROADCAST_DELTA = 122660;
    uint public constant COMPLAINT_BAD_DATA_DELTA = 40720;
    uint public constant PRE_RESPONSE_DELTA = 67780;
    uint public constant COMPLAINT_DELTA = 67100;
    uint public constant RESPONSE_DELTA = 215000;

    // MSR - Minimum staking requirement
    uint public msr;

    // Reward period - 30 days (each 30 days Node would be granted for bounty)
    uint32 public rewardPeriod;

    // Allowable latency - 150000 ms by default
    uint32 public allowableLatency;

    /**
     * Delta period - 1 hour (1 hour before Reward period became Monitors need
     * to send Verdicts and 1 hour after Reward period became Node need to come
     * and get Bounty)
     */
    uint32 public deltaPeriod;

    /**
     * Check time - 2 minutes (every 2 minutes monitors should check metrics
     * from checked nodes)
     */
    uint public checkTime;

    //Need to add minimal allowed parameters for verdicts

    uint public launchTimestamp;

    uint public rotationDelay;

    uint public proofOfUseLockUpPeriodDays;

    uint public proofOfUseDelegationPercentage;

    uint public limitValidatorsPerDelegator;

    uint256 public firstDelegationsMonth; // deprecated

    // date when schains will be allowed for creation
    uint public schainCreationTimeStamp;

    uint public minimalSchainLifetime;

    uint public complaintTimelimit;

    /**
     * @dev Allows the Owner to set new reward and delta periods
     * This function is only for tests.
     */
    function setPeriods(uint32 newRewardPeriod, uint32 newDeltaPeriod) external onlyOwner {
        require(
            newRewardPeriod >= newDeltaPeriod && newRewardPeriod - newDeltaPeriod >= checkTime,
            "Incorrect Periods"
        );
        rewardPeriod = newRewardPeriod;
        deltaPeriod = newDeltaPeriod;
    }

    /**
     * @dev Allows the Owner to set the new check time.
     * This function is only for tests.
     */
    function setCheckTime(uint newCheckTime) external onlyOwner {
        require(rewardPeriod - deltaPeriod >= checkTime, "Incorrect check time");
        checkTime = newCheckTime;
    }    

    /**
     * @dev Allows the Owner to set the allowable latency in milliseconds.
     * This function is only for testing purposes.
     */
    function setLatency(uint32 newAllowableLatency) external onlyOwner {
        allowableLatency = newAllowableLatency;
    }

    /**
     * @dev Allows the Owner to set the minimum stake requirement.
     */
    function setMSR(uint newMSR) external onlyOwner {
        msr = newMSR;
    }

    /**
     * @dev Allows the Owner to set the launch timestamp.
     */
    function setLaunchTimestamp(uint timestamp) external onlyOwner {
        require(now < launchTimestamp, "Cannot set network launch timestamp because network is already launched");
        launchTimestamp = timestamp;
    }

    /**
     * @dev Allows the Owner to set the node rotation delay.
     */
    function setRotationDelay(uint newDelay) external onlyOwner {
        rotationDelay = newDelay;
    }

    /**
     * @dev Allows the Owner to set the proof-of-use lockup period.
     */
    function setProofOfUseLockUpPeriod(uint periodDays) external onlyOwner {
        proofOfUseLockUpPeriodDays = periodDays;
    }

    /**
     * @dev Allows the Owner to set the proof-of-use delegation percentage
     * requirement.
     */
    function setProofOfUseDelegationPercentage(uint percentage) external onlyOwner {
        require(percentage <= 100, "Percentage value is incorrect");
        proofOfUseDelegationPercentage = percentage;
    }

    /**
     * @dev Allows the Owner to set the maximum number of validators that a
     * single delegator can delegate to.
     */
    function setLimitValidatorsPerDelegator(uint newLimit) external onlyOwner {
        limitValidatorsPerDelegator = newLimit;
    }

    function setSchainCreationTimeStamp(uint timestamp) external onlyOwner {
        schainCreationTimeStamp = timestamp;
    }

    function setMinimalSchainLifetime(uint lifetime) external onlyOwner {
        minimalSchainLifetime = lifetime;
    }

    function setComplaintTimelimit(uint timelimit) external onlyOwner {
        complaintTimelimit = timelimit;
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);

        msr = 0;
        rewardPeriod = 2592000;
        allowableLatency = 150000;
        deltaPeriod = 3600;
        checkTime = 300;
        launchTimestamp = uint(-1);
        rotationDelay = 12 hours;
        proofOfUseLockUpPeriodDays = 90;
        proofOfUseDelegationPercentage = 50;
        limitValidatorsPerDelegator = 20;
        firstDelegationsMonth = 0;
        complaintTimelimit = 1800;
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Nodes.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin
    @author Dmytro Stebaiev
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/utils/SafeCast.sol";

import "./delegation/DelegationController.sol";
import "./delegation/ValidatorService.sol";
import "./utils/Random.sol";
import "./utils/SegmentTree.sol";

import "./BountyV2.sol";
import "./ConstantsHolder.sol";
import "./Permissions.sol";


/**
 * @title Nodes
 * @dev This contract contains all logic to manage SKALE Network nodes states,
 * space availability, stake requirement checks, and exit functions.
 * 
 * Nodes may be in one of several states:
 * 
 * - Active:            Node is registered and is in network operation.
 * - Leaving:           Node has begun exiting from the network.
 * - Left:              Node has left the network.
 * - In_Maintenance:    Node is temporarily offline or undergoing infrastructure
 * maintenance
 * 
 * Note: Online nodes contain both Active and Leaving states.
 */
contract Nodes is Permissions {
    
    using Random for Random.RandomGenerator;
    using SafeCast for uint;
    using SegmentTree for SegmentTree.Tree;

    // All Nodes states
    enum NodeStatus {Active, Leaving, Left, In_Maintenance}

    struct Node {
        string name;
        bytes4 ip;
        bytes4 publicIP;
        uint16 port;
        bytes32[2] publicKey;
        uint startBlock;
        uint lastRewardDate;
        uint finishTime;
        NodeStatus status;
        uint validatorId;
    }

    // struct to note which Nodes and which number of Nodes owned by user
    struct CreatedNodes {
        mapping (uint => bool) isNodeExist;
        uint numberOfNodes;
    }

    struct SpaceManaging {
        uint8 freeSpace;
        uint indexInSpaceMap;
    }

    // TODO: move outside the contract
    struct NodeCreationParams {
        string name;
        bytes4 ip;
        bytes4 publicIp;
        uint16 port;
        bytes32[2] publicKey;
        uint16 nonce;
        string domainName;
    }

    // array which contain all Nodes
    Node[] public nodes;

    SpaceManaging[] public spaceOfNodes;

    // mapping for checking which Nodes and which number of Nodes owned by user
    mapping (address => CreatedNodes) public nodeIndexes;
    // mapping for checking is IP address busy
    mapping (bytes4 => bool) public nodesIPCheck;
    // mapping for checking is Name busy
    mapping (bytes32 => bool) public nodesNameCheck;
    // mapping for indication from Name to Index
    mapping (bytes32 => uint) public nodesNameToIndex;
    // mapping for indication from space to Nodes
    mapping (uint8 => uint[]) public spaceToNodes;

    mapping (uint => uint[]) public validatorToNodeIndexes;

    uint public numberOfActiveNodes;
    uint public numberOfLeavingNodes;
    uint public numberOfLeftNodes;

    mapping (uint => string) public domainNames;

    mapping (uint => bool) private _invisible;

    SegmentTree.Tree private _nodesAmountBySpace;

    /**
     * @dev Emitted when a node is created.
     */
    event NodeCreated(
        uint nodeIndex,
        address owner,
        string name,
        bytes4 ip,
        bytes4 publicIP,
        uint16 port,
        uint16 nonce,
        string domainName,
        uint time,
        uint gasSpend
    );

    /**
     * @dev Emitted when a node completes a network exit.
     */
    event ExitCompleted(
        uint nodeIndex,
        uint time,
        uint gasSpend
    );

    /**
     * @dev Emitted when a node begins to exit from the network.
     */
    event ExitInitialized(
        uint nodeIndex,
        uint startLeavingPeriod,
        uint time,
        uint gasSpend
    );

    modifier checkNodeExists(uint nodeIndex) {
        _checkNodeIndex(nodeIndex);
        _;
    }

    modifier onlyNodeOrAdmin(uint nodeIndex) {
        _checkNodeOrAdmin(nodeIndex, msg.sender);
        _;
    }

    function initializeSegmentTreeAndInvisibleNodes() external onlyOwner {
        for (uint i = 0; i < nodes.length; i++) {
            if (nodes[i].status != NodeStatus.Active && nodes[i].status != NodeStatus.Left) {
                _invisible[i] = true;
                _removeNodeFromSpaceToNodes(i, spaceOfNodes[i].freeSpace);
            }
        }
        uint8 totalSpace = ConstantsHolder(contractManager.getContract("ConstantsHolder")).TOTAL_SPACE_ON_NODE();
        _nodesAmountBySpace.create(totalSpace);
        for (uint8 i = 1; i <= totalSpace; i++) {
            if (spaceToNodes[i].length > 0)
                _nodesAmountBySpace.addToPlace(i, spaceToNodes[i].length);
        }
    }

    /**
     * @dev Allows Schains and SchainsInternal contracts to occupy available
     * space on a node.
     * 
     * Returns whether operation is successful.
     */
    function removeSpaceFromNode(uint nodeIndex, uint8 space)
        external
        checkNodeExists(nodeIndex)
        allowTwo("NodeRotation", "SchainsInternal")
        returns (bool)
    {
        if (spaceOfNodes[nodeIndex].freeSpace < space) {
            return false;
        }
        if (space > 0) {
            _moveNodeToNewSpaceMap(
                nodeIndex,
                uint(spaceOfNodes[nodeIndex].freeSpace).sub(space).toUint8()
            );
        }
        return true;
    }

    /**
     * @dev Allows Schains contract to occupy free space on a node.
     * 
     * Returns whether operation is successful.
     */
    function addSpaceToNode(uint nodeIndex, uint8 space)
        external
        checkNodeExists(nodeIndex)
        allowTwo("Schains", "NodeRotation")
    {
        if (space > 0) {
            _moveNodeToNewSpaceMap(
                nodeIndex,
                uint(spaceOfNodes[nodeIndex].freeSpace).add(space).toUint8()
            );
        }
    }

    /**
     * @dev Allows SkaleManager to change a node's last reward date.
     */
    function changeNodeLastRewardDate(uint nodeIndex)
        external
        checkNodeExists(nodeIndex)
        allow("SkaleManager")
    {
        nodes[nodeIndex].lastRewardDate = block.timestamp;
    }

    /**
     * @dev Allows SkaleManager to change a node's finish time.
     */
    function changeNodeFinishTime(uint nodeIndex, uint time)
        external
        checkNodeExists(nodeIndex)
        allow("SkaleManager")
    {
        nodes[nodeIndex].finishTime = time;
    }

    /**
     * @dev Allows SkaleManager contract to create new node and add it to the
     * Nodes contract.
     * 
     * Emits a {NodeCreated} event.
     * 
     * Requirements:
     * 
     * - Node IP must be non-zero.
     * - Node IP must be available.
     * - Node name must not already be registered.
     * - Node port must be greater than zero.
     */
    function createNode(address from, NodeCreationParams calldata params)
        external
        allow("SkaleManager")
    {
        // checks that Node has correct data
        require(params.ip != 0x0 && !nodesIPCheck[params.ip], "IP address is zero or is not available");
        require(!nodesNameCheck[keccak256(abi.encodePacked(params.name))], "Name is already registered");
        require(params.port > 0, "Port is zero");
        require(from == _publicKeyToAddress(params.publicKey), "Public Key is incorrect");
        uint validatorId = ValidatorService(
            contractManager.getContract("ValidatorService")).getValidatorIdByNodeAddress(from);
        uint8 totalSpace = ConstantsHolder(contractManager.getContract("ConstantsHolder")).TOTAL_SPACE_ON_NODE();
        nodes.push(Node({
            name: params.name,
            ip: params.ip,
            publicIP: params.publicIp,
            port: params.port,
            publicKey: params.publicKey,
            startBlock: block.number,
            lastRewardDate: block.timestamp,
            finishTime: 0,
            status: NodeStatus.Active,
            validatorId: validatorId
        }));
        uint nodeIndex = nodes.length.sub(1);
        validatorToNodeIndexes[validatorId].push(nodeIndex);
        bytes32 nodeId = keccak256(abi.encodePacked(params.name));
        nodesIPCheck[params.ip] = true;
        nodesNameCheck[nodeId] = true;
        nodesNameToIndex[nodeId] = nodeIndex;
        nodeIndexes[from].isNodeExist[nodeIndex] = true;
        nodeIndexes[from].numberOfNodes++;
        domainNames[nodeIndex] = params.domainName;
        spaceOfNodes.push(SpaceManaging({
            freeSpace: totalSpace,
            indexInSpaceMap: spaceToNodes[totalSpace].length
        }));
        _setNodeActive(nodeIndex);
        emit NodeCreated(
            nodeIndex,
            from,
            params.name,
            params.ip,
            params.publicIp,
            params.port,
            params.nonce,
            params.domainName,
            block.timestamp,
            gasleft());
    }

    /**
     * @dev Allows SkaleManager contract to initiate a node exit procedure.
     * 
     * Returns whether the operation is successful.
     * 
     * Emits an {ExitInitialized} event.
     */
    function initExit(uint nodeIndex)
        external
        checkNodeExists(nodeIndex)
        allow("SkaleManager")
        returns (bool)
    {
        require(isNodeActive(nodeIndex), "Node should be Active");
    
        _setNodeLeaving(nodeIndex);

        emit ExitInitialized(
            nodeIndex,
            block.timestamp,
            block.timestamp,
            gasleft());
        return true;
    }

    /**
     * @dev Allows SkaleManager contract to complete a node exit procedure.
     * 
     * Returns whether the operation is successful.
     * 
     * Emits an {ExitCompleted} event.
     * 
     * Requirements:
     * 
     * - Node must have already initialized a node exit procedure.
     */
    function completeExit(uint nodeIndex)
        external
        checkNodeExists(nodeIndex)
        allow("SkaleManager")
        returns (bool)
    {
        require(isNodeLeaving(nodeIndex), "Node is not Leaving");

        _setNodeLeft(nodeIndex);

        emit ExitCompleted(
            nodeIndex,
            block.timestamp,
            gasleft());
        return true;
    }

    /**
     * @dev Allows SkaleManager contract to delete a validator's node.
     * 
     * Requirements:
     * 
     * - Validator ID must exist.
     */
    function deleteNodeForValidator(uint validatorId, uint nodeIndex)
        external
        checkNodeExists(nodeIndex)
        allow("SkaleManager")
    {
        ValidatorService validatorService = ValidatorService(contractManager.getValidatorService());
        require(validatorService.validatorExists(validatorId), "Validator ID does not exist");
        uint[] memory validatorNodes = validatorToNodeIndexes[validatorId];
        uint position = _findNode(validatorNodes, nodeIndex);
        if (position < validatorNodes.length) {
            validatorToNodeIndexes[validatorId][position] =
                validatorToNodeIndexes[validatorId][validatorNodes.length.sub(1)];
        }
        validatorToNodeIndexes[validatorId].pop();
        address nodeOwner = _publicKeyToAddress(nodes[nodeIndex].publicKey);
        if (validatorService.getValidatorIdByNodeAddress(nodeOwner) == validatorId) {
            if (nodeIndexes[nodeOwner].numberOfNodes == 1 && !validatorService.validatorAddressExists(nodeOwner)) {
                validatorService.removeNodeAddress(validatorId, nodeOwner);
            }
            nodeIndexes[nodeOwner].isNodeExist[nodeIndex] = false;
            nodeIndexes[nodeOwner].numberOfNodes--;
        }
    }

    /**
     * @dev Allows SkaleManager contract to check whether a validator has
     * sufficient stake to create another node.
     * 
     * Requirements:
     * 
     * - Validator must be included on trusted list if trusted list is enabled.
     * - Validator must have sufficient stake to operate an additional node.
     */
    function checkPossibilityCreatingNode(address nodeAddress) external allow("SkaleManager") {
        ValidatorService validatorService = ValidatorService(contractManager.getValidatorService());
        uint validatorId = validatorService.getValidatorIdByNodeAddress(nodeAddress);
        require(validatorService.isAuthorizedValidator(validatorId), "Validator is not authorized to create a node");
        require(
            _checkValidatorPositionToMaintainNode(validatorId, validatorToNodeIndexes[validatorId].length),
            "Validator must meet the Minimum Staking Requirement");
    }

    /**
     * @dev Allows SkaleManager contract to check whether a validator has
     * sufficient stake to maintain a node.
     * 
     * Returns whether validator can maintain node with current stake.
     * 
     * Requirements:
     * 
     * - Validator ID and nodeIndex must both exist.
     */
    function checkPossibilityToMaintainNode(
        uint validatorId,
        uint nodeIndex
    )
        external
        checkNodeExists(nodeIndex)
        allow("Bounty")
        returns (bool)
    {
        ValidatorService validatorService = ValidatorService(contractManager.getValidatorService());
        require(validatorService.validatorExists(validatorId), "Validator ID does not exist");
        uint[] memory validatorNodes = validatorToNodeIndexes[validatorId];
        uint position = _findNode(validatorNodes, nodeIndex);
        require(position < validatorNodes.length, "Node does not exist for this Validator");
        return _checkValidatorPositionToMaintainNode(validatorId, position);
    }

    /**
     * @dev Allows Node to set In_Maintenance status.
     * 
     * Requirements:
     * 
     * - Node must already be Active.
     * - `msg.sender` must be owner of Node, validator, or SkaleManager.
     */
    function setNodeInMaintenance(uint nodeIndex) external onlyNodeOrAdmin(nodeIndex) {
        require(nodes[nodeIndex].status == NodeStatus.Active, "Node is not Active");
        _setNodeInMaintenance(nodeIndex);
    }

    /**
     * @dev Allows Node to remove In_Maintenance status.
     * 
     * Requirements:
     * 
     * - Node must already be In Maintenance.
     * - `msg.sender` must be owner of Node, validator, or SkaleManager.
     */
    function removeNodeFromInMaintenance(uint nodeIndex) external onlyNodeOrAdmin(nodeIndex) {
        require(nodes[nodeIndex].status == NodeStatus.In_Maintenance, "Node is not In Maintenance");
        _setNodeActive(nodeIndex);
    }

    function setDomainName(uint nodeIndex, string memory domainName)
        external
        onlyNodeOrAdmin(nodeIndex)
    {
        domainNames[nodeIndex] = domainName;
    }
    
    function makeNodeVisible(uint nodeIndex) external allow("SchainsInternal") {
        _makeNodeVisible(nodeIndex);
    }

    function makeNodeInvisible(uint nodeIndex) external allow("SchainsInternal") {
        _makeNodeInvisible(nodeIndex);
    }

    function getRandomNodeWithFreeSpace(
        uint8 freeSpace,
        Random.RandomGenerator memory randomGenerator
    )
        external
        view
        returns (uint)
    {
        uint8 place = _nodesAmountBySpace.getRandomNonZeroElementFromPlaceToLast(
            freeSpace == 0 ? 1 : freeSpace,
            randomGenerator
        ).toUint8();
        require(place > 0, "Node not found");
        return spaceToNodes[place][randomGenerator.random(spaceToNodes[place].length)]; 
    }

    /**
     * @dev Checks whether it is time for a node's reward.
     */
    function isTimeForReward(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (bool)
    {
        return BountyV2(contractManager.getBounty()).getNextRewardTimestamp(nodeIndex) <= now;
    }

    /**
     * @dev Returns IP address of a given node.
     * 
     * Requirements:
     * 
     * - Node must exist.
     */
    function getNodeIP(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (bytes4)
    {
        require(nodeIndex < nodes.length, "Node does not exist");
        return nodes[nodeIndex].ip;
    }

    /**
     * @dev Returns domain name of a given node.
     * 
     * Requirements:
     * 
     * - Node must exist.
     */
    function getNodeDomainName(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (string memory)
    {
        return domainNames[nodeIndex];
    }

    /**
     * @dev Returns the port of a given node.
     *
     * Requirements:
     *
     * - Node must exist.
     */
    function getNodePort(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (uint16)
    {
        return nodes[nodeIndex].port;
    }

    /**
     * @dev Returns the public key of a given node.
     */
    function getNodePublicKey(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (bytes32[2] memory)
    {
        return nodes[nodeIndex].publicKey;
    }

    /**
     * @dev Returns an address of a given node.
     */
    function getNodeAddress(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (address)
    {
        return _publicKeyToAddress(nodes[nodeIndex].publicKey);
    }


    /**
     * @dev Returns the finish exit time of a given node.
     */
    function getNodeFinishTime(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (uint)
    {
        return nodes[nodeIndex].finishTime;
    }

    /**
     * @dev Checks whether a node has left the network.
     */
    function isNodeLeft(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (bool)
    {
        return nodes[nodeIndex].status == NodeStatus.Left;
    }

    function isNodeInMaintenance(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (bool)
    {
        return nodes[nodeIndex].status == NodeStatus.In_Maintenance;
    }

    /**
     * @dev Returns a given node's last reward date.
     */
    function getNodeLastRewardDate(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (uint)
    {
        return nodes[nodeIndex].lastRewardDate;
    }

    /**
     * @dev Returns a given node's next reward date.
     */
    function getNodeNextRewardDate(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (uint)
    {
        return BountyV2(contractManager.getBounty()).getNextRewardTimestamp(nodeIndex);
    }

    /**
     * @dev Returns the total number of registered nodes.
     */
    function getNumberOfNodes() external view returns (uint) {
        return nodes.length;
    }

    /**
     * @dev Returns the total number of online nodes.
     * 
     * Note: Online nodes are equal to the number of active plus leaving nodes.
     */
    function getNumberOnlineNodes() external view returns (uint) {
        return numberOfActiveNodes.add(numberOfLeavingNodes);
    }

    /**
     * @dev Return active node IDs.
     */
    function getActiveNodeIds() external view returns (uint[] memory activeNodeIds) {
        activeNodeIds = new uint[](numberOfActiveNodes);
        uint indexOfActiveNodeIds = 0;
        for (uint indexOfNodes = 0; indexOfNodes < nodes.length; indexOfNodes++) {
            if (isNodeActive(indexOfNodes)) {
                activeNodeIds[indexOfActiveNodeIds] = indexOfNodes;
                indexOfActiveNodeIds++;
            }
        }
    }

    /**
     * @dev Return a given node's current status.
     */
    function getNodeStatus(uint nodeIndex)
        external
        view
        checkNodeExists(nodeIndex)
        returns (NodeStatus)
    {
        return nodes[nodeIndex].status;
    }

    /**
     * @dev Return a validator's linked nodes.
     * 
     * Requirements:
     * 
     * - Validator ID must exist.
     */
    function getValidatorNodeIndexes(uint validatorId) external view returns (uint[] memory) {
        ValidatorService validatorService = ValidatorService(contractManager.getValidatorService());
        require(validatorService.validatorExists(validatorId), "Validator ID does not exist");
        return validatorToNodeIndexes[validatorId];
    }

    /**
     * @dev Returns number of nodes with available space.
     */
    function countNodesWithFreeSpace(uint8 freeSpace) external view returns (uint count) {
        if (freeSpace == 0) {
            return _nodesAmountBySpace.sumFromPlaceToLast(1);
        }
        return _nodesAmountBySpace.sumFromPlaceToLast(freeSpace);
    }

    /**
     * @dev constructor in Permissions approach.
     */
    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);

        numberOfActiveNodes = 0;
        numberOfLeavingNodes = 0;
        numberOfLeftNodes = 0;
        _nodesAmountBySpace.create(128);
    }

    /**
     * @dev Returns the Validator ID for a given node.
     */
    function getValidatorId(uint nodeIndex)
        public
        view
        checkNodeExists(nodeIndex)
        returns (uint)
    {
        return nodes[nodeIndex].validatorId;
    }

    /**
     * @dev Checks whether a node exists for a given address.
     */
    function isNodeExist(address from, uint nodeIndex)
        public
        view
        checkNodeExists(nodeIndex)
        returns (bool)
    {
        return nodeIndexes[from].isNodeExist[nodeIndex];
    }

    /**
     * @dev Checks whether a node's status is Active.
     */
    function isNodeActive(uint nodeIndex)
        public
        view
        checkNodeExists(nodeIndex)
        returns (bool)
    {
        return nodes[nodeIndex].status == NodeStatus.Active;
    }

    /**
     * @dev Checks whether a node's status is Leaving.
     */
    function isNodeLeaving(uint nodeIndex)
        public
        view
        checkNodeExists(nodeIndex)
        returns (bool)
    {
        return nodes[nodeIndex].status == NodeStatus.Leaving;
    }

    function _removeNodeFromSpaceToNodes(uint nodeIndex, uint8 space) internal {
        uint indexInArray = spaceOfNodes[nodeIndex].indexInSpaceMap;
        uint len = spaceToNodes[space].length.sub(1);
        if (indexInArray < len) {
            uint shiftedIndex = spaceToNodes[space][len];
            spaceToNodes[space][indexInArray] = shiftedIndex;
            spaceOfNodes[shiftedIndex].indexInSpaceMap = indexInArray;
        }
        spaceToNodes[space].pop();
        delete spaceOfNodes[nodeIndex].indexInSpaceMap;
    }

    function _getNodesAmountBySpace() internal view returns (SegmentTree.Tree storage) {
        return _nodesAmountBySpace;
    }

    /**
     * @dev Returns the index of a given node within the validator's node index.
     */
    function _findNode(uint[] memory validatorNodeIndexes, uint nodeIndex) private pure returns (uint) {
        uint i;
        for (i = 0; i < validatorNodeIndexes.length; i++) {
            if (validatorNodeIndexes[i] == nodeIndex) {
                return i;
            }
        }
        return validatorNodeIndexes.length;
    }

    /**
     * @dev Moves a node to a new space mapping.
     */
    function _moveNodeToNewSpaceMap(uint nodeIndex, uint8 newSpace) private {
        if (!_invisible[nodeIndex]) {
            uint8 space = spaceOfNodes[nodeIndex].freeSpace;
            _removeNodeFromTree(space);
            _addNodeToTree(newSpace);
            _removeNodeFromSpaceToNodes(nodeIndex, space);
            _addNodeToSpaceToNodes(nodeIndex, newSpace);
        }
        spaceOfNodes[nodeIndex].freeSpace = newSpace;
    }

    /**
     * @dev Changes a node's status to Active.
     */
    function _setNodeActive(uint nodeIndex) private {
        nodes[nodeIndex].status = NodeStatus.Active;
        numberOfActiveNodes = numberOfActiveNodes.add(1);
        if (_invisible[nodeIndex]) {
            _makeNodeVisible(nodeIndex);
        } else {
            uint8 space = spaceOfNodes[nodeIndex].freeSpace;
            _addNodeToSpaceToNodes(nodeIndex, space);
            _addNodeToTree(space);
        }
    }

    /**
     * @dev Changes a node's status to In_Maintenance.
     */
    function _setNodeInMaintenance(uint nodeIndex) private {
        nodes[nodeIndex].status = NodeStatus.In_Maintenance;
        numberOfActiveNodes = numberOfActiveNodes.sub(1);
        _makeNodeInvisible(nodeIndex);
    }

    /**
     * @dev Changes a node's status to Left.
     */
    function _setNodeLeft(uint nodeIndex) private {
        nodesIPCheck[nodes[nodeIndex].ip] = false;
        nodesNameCheck[keccak256(abi.encodePacked(nodes[nodeIndex].name))] = false;
        delete nodesNameToIndex[keccak256(abi.encodePacked(nodes[nodeIndex].name))];
        if (nodes[nodeIndex].status == NodeStatus.Active) {
            numberOfActiveNodes--;
        } else {
            numberOfLeavingNodes--;
        }
        nodes[nodeIndex].status = NodeStatus.Left;
        numberOfLeftNodes++;
        delete spaceOfNodes[nodeIndex].freeSpace;
    }

    /**
     * @dev Changes a node's status to Leaving.
     */
    function _setNodeLeaving(uint nodeIndex) private {
        nodes[nodeIndex].status = NodeStatus.Leaving;
        numberOfActiveNodes--;
        numberOfLeavingNodes++;
        _makeNodeInvisible(nodeIndex);
    }

    function _makeNodeInvisible(uint nodeIndex) private {
        if (!_invisible[nodeIndex]) {
            uint8 space = spaceOfNodes[nodeIndex].freeSpace;
            _removeNodeFromSpaceToNodes(nodeIndex, space);
            _removeNodeFromTree(space);
            _invisible[nodeIndex] = true;
        }
    }

    function _makeNodeVisible(uint nodeIndex) private {
        if (_invisible[nodeIndex]) {
            uint8 space = spaceOfNodes[nodeIndex].freeSpace;
            _addNodeToSpaceToNodes(nodeIndex, space);
            _addNodeToTree(space);
            delete _invisible[nodeIndex];
        }
    }

    function _addNodeToSpaceToNodes(uint nodeIndex, uint8 space) private {
        spaceToNodes[space].push(nodeIndex);
        spaceOfNodes[nodeIndex].indexInSpaceMap = spaceToNodes[space].length.sub(1);
    }

    function _addNodeToTree(uint8 space) private {
        if (space > 0) {
            _nodesAmountBySpace.addToPlace(space, 1);
        }
    }

    function _removeNodeFromTree(uint8 space) private {
        if (space > 0) {
            _nodesAmountBySpace.removeFromPlace(space, 1);
        }
    }

    function _checkValidatorPositionToMaintainNode(uint validatorId, uint position) private returns (bool) {
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController")
        );
        uint delegationsTotal = delegationController.getAndUpdateDelegatedToValidatorNow(validatorId);
        uint msr = ConstantsHolder(contractManager.getConstantsHolder()).msr();
        return position.add(1).mul(msr) <= delegationsTotal;
    }

    function _checkNodeIndex(uint nodeIndex) private view {
        require(nodeIndex < nodes.length, "Node with such index does not exist");
    }

    function _checkNodeOrAdmin(uint nodeIndex, address sender) private view {
        ValidatorService validatorService = ValidatorService(contractManager.getValidatorService());

        require(
            isNodeExist(sender, nodeIndex) ||
            _isAdmin(sender) ||
            getValidatorId(nodeIndex) == validatorService.getValidatorId(sender),
            "Sender is not permitted to call this function"
        );
    }

    function _publicKeyToAddress(bytes32[2] memory pubKey) private pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(pubKey[0], pubKey[1]));
        bytes20 addr;
        for (uint8 i = 12; i < 32; i++) {
            addr |= bytes20(hash[i] & 0xFF) >> ((i - 12) * 8);
        }
        return address(addr);
    }

    function _min(uint a, uint b) private pure returns (uint) {
        if (a < b) {
            return a;
        } else {
            return b;
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Permissions.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/AccessControl.sol";

import "./ContractManager.sol";


/**
 * @title Permissions
 * @dev Contract is connected module for Upgradeable approach, knows ContractManager
 */
contract Permissions is AccessControlUpgradeSafe {
    using SafeMath for uint;
    using Address for address;
    
    ContractManager public contractManager;

    /**
     * @dev Modifier to make a function callable only when caller is the Owner.
     * 
     * Requirements:
     * 
     * - The caller must be the owner.
     */
    modifier onlyOwner() {
        require(_isOwner(), "Caller is not the owner");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when caller is an Admin.
     * 
     * Requirements:
     * 
     * - The caller must be an admin.
     */
    modifier onlyAdmin() {
        require(_isAdmin(msg.sender), "Caller is not an admin");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when caller is the Owner 
     * or `contractName` contract.
     * 
     * Requirements:
     * 
     * - The caller must be the owner or `contractName`.
     */
    modifier allow(string memory contractName) {
        require(
            contractManager.getContract(contractName) == msg.sender || _isOwner(),
            "Message sender is invalid");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when caller is the Owner 
     * or `contractName1` or `contractName2` contract.
     * 
     * Requirements:
     * 
     * - The caller must be the owner, `contractName1`, or `contractName2`.
     */
    modifier allowTwo(string memory contractName1, string memory contractName2) {
        require(
            contractManager.getContract(contractName1) == msg.sender ||
            contractManager.getContract(contractName2) == msg.sender ||
            _isOwner(),
            "Message sender is invalid");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when caller is the Owner 
     * or `contractName1`, `contractName2`, or `contractName3` contract.
     * 
     * Requirements:
     * 
     * - The caller must be the owner, `contractName1`, `contractName2`, or 
     * `contractName3`.
     */
    modifier allowThree(string memory contractName1, string memory contractName2, string memory contractName3) {
        require(
            contractManager.getContract(contractName1) == msg.sender ||
            contractManager.getContract(contractName2) == msg.sender ||
            contractManager.getContract(contractName3) == msg.sender ||
            _isOwner(),
            "Message sender is invalid");
        _;
    }

    function initialize(address contractManagerAddress) public virtual initializer {
        AccessControlUpgradeSafe.__AccessControl_init();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setContractManager(contractManagerAddress);
    }

    function _isOwner() internal view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function _isAdmin(address account) internal view returns (bool) {
        address skaleManagerAddress = contractManager.contracts(keccak256(abi.encodePacked("SkaleManager")));
        if (skaleManagerAddress != address(0)) {
            AccessControlUpgradeSafe skaleManager = AccessControlUpgradeSafe(skaleManagerAddress);
            return skaleManager.hasRole(keccak256("ADMIN_ROLE"), account) || _isOwner();
        } else {
            return _isOwner();
        }
    }

    function _setContractManager(address contractManagerAddress) private {
        require(contractManagerAddress != address(0), "ContractManager address is not set");
        require(contractManagerAddress.isContract(), "Address is not contract");
        contractManager = ContractManager(contractManagerAddress);
    }
}

pragma solidity ^0.6.0;

/**
 * @dev Interface of the ERC777Token standard as defined in the EIP.
 *
 * This contract uses the
 * https://eips.ethereum.org/EIPS/eip-1820[ERC1820 registry standard] to let
 * token holders and recipients react to token movements by using setting implementers
 * for the associated interfaces in said registry. See {IERC1820Registry} and
 * {ERC1820Implementer}.
 */
interface IERC777 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the smallest part of the token that is not divisible. This
     * means all token operations (creation, movement and destruction) must have
     * amounts that are a multiple of this number.
     *
     * For most token contracts, this value will equal 1.
     */
    function granularity() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by an account (`owner`).
     */
    function balanceOf(address owner) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * If send or receive hooks are registered for the caller and `recipient`,
     * the corresponding functions will be called with `data` and empty
     * `operatorData`. See {IERC777Sender} and {IERC777Recipient}.
     *
     * Emits a {Sent} event.
     *
     * Requirements
     *
     * - the caller must have at least `amount` tokens.
     * - `recipient` cannot be the zero address.
     * - if `recipient` is a contract, it must implement the {IERC777Recipient}
     * interface.
     */
    function send(address recipient, uint256 amount, bytes calldata data) external;

    /**
     * @dev Destroys `amount` tokens from the caller's account, reducing the
     * total supply.
     *
     * If a send hook is registered for the caller, the corresponding function
     * will be called with `data` and empty `operatorData`. See {IERC777Sender}.
     *
     * Emits a {Burned} event.
     *
     * Requirements
     *
     * - the caller must have at least `amount` tokens.
     */
    function burn(uint256 amount, bytes calldata data) external;

    /**
     * @dev Returns true if an account is an operator of `tokenHolder`.
     * Operators can send and burn tokens on behalf of their owners. All
     * accounts are their own operator.
     *
     * See {operatorSend} and {operatorBurn}.
     */
    function isOperatorFor(address operator, address tokenHolder) external view returns (bool);

    /**
     * @dev Make an account an operator of the caller.
     *
     * See {isOperatorFor}.
     *
     * Emits an {AuthorizedOperator} event.
     *
     * Requirements
     *
     * - `operator` cannot be calling address.
     */
    function authorizeOperator(address operator) external;

    /**
     * @dev Revoke an account's operator status for the caller.
     *
     * See {isOperatorFor} and {defaultOperators}.
     *
     * Emits a {RevokedOperator} event.
     *
     * Requirements
     *
     * - `operator` cannot be calling address.
     */
    function revokeOperator(address operator) external;

    /**
     * @dev Returns the list of default operators. These accounts are operators
     * for all token holders, even if {authorizeOperator} was never called on
     * them.
     *
     * This list is immutable, but individual holders may revoke these via
     * {revokeOperator}, in which case {isOperatorFor} will return false.
     */
    function defaultOperators() external view returns (address[] memory);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient`. The caller must
     * be an operator of `sender`.
     *
     * If send or receive hooks are registered for `sender` and `recipient`,
     * the corresponding functions will be called with `data` and
     * `operatorData`. See {IERC777Sender} and {IERC777Recipient}.
     *
     * Emits a {Sent} event.
     *
     * Requirements
     *
     * - `sender` cannot be the zero address.
     * - `sender` must have at least `amount` tokens.
     * - the caller must be an operator for `sender`.
     * - `recipient` cannot be the zero address.
     * - if `recipient` is a contract, it must implement the {IERC777Recipient}
     * interface.
     */
    function operatorSend(
        address sender,
        address recipient,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) external;

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the total supply.
     * The caller must be an operator of `account`.
     *
     * If a send hook is registered for `account`, the corresponding function
     * will be called with `data` and `operatorData`. See {IERC777Sender}.
     *
     * Emits a {Burned} event.
     *
     * Requirements
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     * - the caller must be an operator for `account`.
     */
    function operatorBurn(
        address account,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) external;

    event Sent(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 amount,
        bytes data,
        bytes operatorData
    );

    event Minted(address indexed operator, address indexed to, uint256 amount, bytes data, bytes operatorData);

    event Burned(address indexed operator, address indexed from, uint256 amount, bytes data, bytes operatorData);

    event AuthorizedOperator(address indexed operator, address indexed tokenHolder);

    event RevokedOperator(address indexed operator, address indexed tokenHolder);
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    FractionUtils.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";


library FractionUtils {
    using SafeMath for uint;

    struct Fraction {
        uint numerator;
        uint denominator;
    }

    function createFraction(uint numerator, uint denominator) internal pure returns (Fraction memory) {
        require(denominator > 0, "Division by zero");
        Fraction memory fraction = Fraction({numerator: numerator, denominator: denominator});
        reduceFraction(fraction);
        return fraction;
    }

    function createFraction(uint value) internal pure returns (Fraction memory) {
        return createFraction(value, 1);
    }

    function reduceFraction(Fraction memory fraction) internal pure {
        uint _gcd = gcd(fraction.numerator, fraction.denominator);
        fraction.numerator = fraction.numerator.div(_gcd);
        fraction.denominator = fraction.denominator.div(_gcd);
    }
    
    // numerator - is limited by 7*10^27, we could multiply it numerator * numerator - it would less than 2^256-1
    function multiplyFraction(Fraction memory a, Fraction memory b) internal pure returns (Fraction memory) {
        return createFraction(a.numerator.mul(b.numerator), a.denominator.mul(b.denominator));
    }

    function gcd(uint a, uint b) internal pure returns (uint) {
        uint _a = a;
        uint _b = b;
        if (_b > _a) {
            (_a, _b) = swap(_a, _b);
        }
        while (_b > 0) {
            _a = _a.mod(_b);
            (_a, _b) = swap (_a, _b);
        }
        return _a;
    }

    function swap(uint a, uint b) internal pure returns (uint, uint) {
        return (b, a);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    MathUtils.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;


library MathUtils {

    uint constant private _EPS = 1e6;

    event UnderflowError(
        uint a,
        uint b
    );    

    function boundedSub(uint256 a, uint256 b) internal returns (uint256) {
        if (a >= b) {
            return a - b;
        } else {
            emit UnderflowError(a, b);
            return 0;
        }
    }

    function boundedSubWithoutEvent(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a >= b) {
            return a - b;
        } else {
            return 0;
        }
    }

    function muchGreater(uint256 a, uint256 b) internal pure returns (bool) {
        assert(uint(-1) - _EPS > b);
        return a > b + _EPS;
    }

    function approximatelyEqual(uint256 a, uint256 b) internal pure returns (bool) {
        if (a > b) {
            return a - b < _EPS;
        } else {
            return b - a < _EPS;
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    DelegationPeriodManager.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "../Permissions.sol";

/**
 * @title Delegation Period Manager
 * @dev This contract handles all delegation offerings. Delegations are held for
 * a specified period (months), and different durations can have different
 * returns or `stakeMultiplier`. Currently, only delegation periods can be added.
 */
contract DelegationPeriodManager is Permissions {

    mapping (uint => uint) public stakeMultipliers;

    /**
     * @dev Emitted when a new delegation period is specified.
     */
    event DelegationPeriodWasSet(
        uint length,
        uint stakeMultiplier
    );

    /**
     * @dev Allows the Owner to create a new available delegation period and
     * stake multiplier in the network.
     * 
     * Emits a {DelegationPeriodWasSet} event.
     */
    function setDelegationPeriod(uint monthsCount, uint stakeMultiplier) external onlyOwner {
        require(stakeMultipliers[monthsCount] == 0, "Delegation perios is already set");
        stakeMultipliers[monthsCount] = stakeMultiplier;

        emit DelegationPeriodWasSet(monthsCount, stakeMultiplier);
    }

    /**
     * @dev Checks whether given delegation period is allowed.
     */
    function isDelegationPeriodAllowed(uint monthsCount) external view returns (bool) {
        return stakeMultipliers[monthsCount] != 0;
    }

    /**
     * @dev Initial delegation period and multiplier settings.
     */
    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
        stakeMultipliers[2] = 100;  // 2 months at 100
        // stakeMultipliers[6] = 150;  // 6 months at 150
        // stakeMultipliers[12] = 200; // 12 months at 200
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Punisher.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "../Permissions.sol";
import "../interfaces/delegation/ILocker.sol";

import "./ValidatorService.sol";
import "./DelegationController.sol";

/**
 * @title Punisher
 * @dev This contract handles all slashing and forgiving operations.
 */
contract Punisher is Permissions, ILocker {

    //        holder => tokens
    mapping (address => uint) private _locked;

    /**
     * @dev Emitted upon slashing condition.
     */
    event Slash(
        uint validatorId,
        uint amount
    );

    /**
     * @dev Emitted upon forgive condition.
     */
    event Forgive(
        address wallet,
        uint amount
    );

    /**
     * @dev Allows SkaleDKG contract to execute slashing on a validator and
     * validator's delegations by an `amount` of tokens.
     * 
     * Emits a {Slash} event.
     * 
     * Requirements:
     * 
     * - Validator must exist.
     */
    function slash(uint validatorId, uint amount) external allow("SkaleDKG") {
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController"));

        require(validatorService.validatorExists(validatorId), "Validator does not exist");

        delegationController.confiscate(validatorId, amount);

        emit Slash(validatorId, amount);
    }

    /**
     * @dev Allows the Admin to forgive a slashing condition.
     * 
     * Emits a {Forgive} event.
     * 
     * Requirements:
     * 
     * - All slashes must have been processed.
     */
    function forgive(address holder, uint amount) external onlyAdmin {
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController"));

        require(!delegationController.hasUnprocessedSlashes(holder), "Not all slashes were calculated");

        if (amount > _locked[holder]) {
            delete _locked[holder];
        } else {
            _locked[holder] = _locked[holder].sub(amount);
        }

        emit Forgive(holder, amount);
    }

    /**
     * @dev See {ILocker-getAndUpdateLockedAmount}.
     */
    function getAndUpdateLockedAmount(address wallet) external override returns (uint) {
        return _getAndUpdateLockedAmount(wallet);
    }

    /**
     * @dev See {ILocker-getAndUpdateForbiddenForDelegationAmount}.
     */
    function getAndUpdateForbiddenForDelegationAmount(address wallet) external override returns (uint) {
        return _getAndUpdateLockedAmount(wallet);
    }

    /**
     * @dev Allows DelegationController contract to execute slashing of
     * delegations.
     */
    function handleSlash(address holder, uint amount) external allow("DelegationController") {
        _locked[holder] = _locked[holder].add(amount);
    }

    function initialize(address contractManagerAddress) public override initializer {
        Permissions.initialize(contractManagerAddress);
    }

    // private

    /**
     * @dev See {ILocker-getAndUpdateLockedAmount}.
     */
    function _getAndUpdateLockedAmount(address wallet) private returns (uint) {
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController"));

        delegationController.processAllSlashes(wallet);
        return _locked[wallet];
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    TokenState.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../interfaces/delegation/ILocker.sol";
import "../Permissions.sol";

import "./DelegationController.sol";
import "./TimeHelpers.sol";


/**
 * @title Token State
 * @dev This contract manages lockers to control token transferability.
 * 
 * The SKALE Network has three types of locked tokens:
 * 
 * - Tokens that are transferrable but are currently locked into delegation with
 * a validator.
 * 
 * - Tokens that are not transferable from one address to another, but may be
 * delegated to a validator `getAndUpdateLockedAmount`. This lock enforces
 * Proof-of-Use requirements.
 * 
 * - Tokens that are neither transferable nor delegatable
 * `getAndUpdateForbiddenForDelegationAmount`. This lock enforces slashing.
 */
contract TokenState is Permissions, ILocker {

    string[] private _lockers;

    DelegationController private _delegationController;

    /**
     * @dev Emitted when a contract is added to the locker.
     */
    event LockerWasAdded(
        string locker
    );

    /**
     * @dev Emitted when a contract is removed from the locker.
     */
    event LockerWasRemoved(
        string locker
    );

    /**
     *  @dev See {ILocker-getAndUpdateLockedAmount}.
     */
    function getAndUpdateLockedAmount(address holder) external override returns (uint) {
        if (address(_delegationController) == address(0)) {
            _delegationController =
                DelegationController(contractManager.getContract("DelegationController"));
        }
        uint locked = 0;
        if (_delegationController.getDelegationsByHolderLength(holder) > 0) {
            // the holder ever delegated
            for (uint i = 0; i < _lockers.length; ++i) {
                ILocker locker = ILocker(contractManager.getContract(_lockers[i]));
                locked = locked.add(locker.getAndUpdateLockedAmount(holder));
            }
        }
        return locked;
    }

    /**
     * @dev See {ILocker-getAndUpdateForbiddenForDelegationAmount}.
     */
    function getAndUpdateForbiddenForDelegationAmount(address holder) external override returns (uint amount) {
        uint forbidden = 0;
        for (uint i = 0; i < _lockers.length; ++i) {
            ILocker locker = ILocker(contractManager.getContract(_lockers[i]));
            forbidden = forbidden.add(locker.getAndUpdateForbiddenForDelegationAmount(holder));
        }
        return forbidden;
    }

    /**
     * @dev Allows the Owner to remove a contract from the locker.
     * 
     * Emits a {LockerWasRemoved} event.
     */
    function removeLocker(string calldata locker) external onlyOwner {
        uint index;
        bytes32 hash = keccak256(abi.encodePacked(locker));
        for (index = 0; index < _lockers.length; ++index) {
            if (keccak256(abi.encodePacked(_lockers[index])) == hash) {
                break;
            }
        }
        if (index < _lockers.length) {
            if (index < _lockers.length.sub(1)) {
                _lockers[index] = _lockers[_lockers.length.sub(1)];
            }
            delete _lockers[_lockers.length.sub(1)];
            _lockers.pop();
            emit LockerWasRemoved(locker);
        }
    }

    function initialize(address contractManagerAddress) public override initializer {
        Permissions.initialize(contractManagerAddress);
        addLocker("DelegationController");
        addLocker("Punisher");
    }

    /**
     * @dev Allows the Owner to add a contract to the Locker.
     * 
     * Emits a {LockerWasAdded} event.
     */
    function addLocker(string memory locker) public onlyOwner {
        _lockers.push(locker);
        emit LockerWasAdded(locker);
    }
}

pragma solidity ^0.6.0;

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
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
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
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts with custom message when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

pragma solidity ^0.6.0;

// ----------------------------------------------------------------------------
// BokkyPooBah's DateTime Library v1.01
//
// A gas-efficient Solidity date and time library
//
// https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary
//
// Tested date range 1970/01/01 to 2345/12/31
//
// Conventions:
// Unit      | Range         | Notes
// :-------- |:-------------:|:-----
// timestamp | >= 0          | Unix timestamp, number of seconds since 1970/01/01 00:00:00 UTC
// year      | 1970 ... 2345 |
// month     | 1 ... 12      |
// day       | 1 ... 31      |
// hour      | 0 ... 23      |
// minute    | 0 ... 59      |
// second    | 0 ... 59      |
// dayOfWeek | 1 ... 7       | 1 = Monday, ..., 7 = Sunday
//
//
// Enjoy. (c) BokkyPooBah / Bok Consulting Pty Ltd 2018-2019. The MIT Licence.
// ----------------------------------------------------------------------------

library BokkyPooBahsDateTimeLibrary {

    uint constant SECONDS_PER_DAY = 24 * 60 * 60;
    uint constant SECONDS_PER_HOUR = 60 * 60;
    uint constant SECONDS_PER_MINUTE = 60;
    int constant OFFSET19700101 = 2440588;

    uint constant DOW_MON = 1;
    uint constant DOW_TUE = 2;
    uint constant DOW_WED = 3;
    uint constant DOW_THU = 4;
    uint constant DOW_FRI = 5;
    uint constant DOW_SAT = 6;
    uint constant DOW_SUN = 7;

    // ------------------------------------------------------------------------
    // Calculate the number of days from 1970/01/01 to year/month/day using
    // the date conversion algorithm from
    //   http://aa.usno.navy.mil/faq/docs/JD_Formula.php
    // and subtracting the offset 2440588 so that 1970/01/01 is day 0
    //
    // days = day
    //      - 32075
    //      + 1461 * (year + 4800 + (month - 14) / 12) / 4
    //      + 367 * (month - 2 - (month - 14) / 12 * 12) / 12
    //      - 3 * ((year + 4900 + (month - 14) / 12) / 100) / 4
    //      - offset
    // ------------------------------------------------------------------------
    function _daysFromDate(uint year, uint month, uint day) internal pure returns (uint _days) {
        require(year >= 1970);
        int _year = int(year);
        int _month = int(month);
        int _day = int(day);

        int __days = _day
          - 32075
          + 1461 * (_year + 4800 + (_month - 14) / 12) / 4
          + 367 * (_month - 2 - (_month - 14) / 12 * 12) / 12
          - 3 * ((_year + 4900 + (_month - 14) / 12) / 100) / 4
          - OFFSET19700101;

        _days = uint(__days);
    }

    // ------------------------------------------------------------------------
    // Calculate year/month/day from the number of days since 1970/01/01 using
    // the date conversion algorithm from
    //   http://aa.usno.navy.mil/faq/docs/JD_Formula.php
    // and adding the offset 2440588 so that 1970/01/01 is day 0
    //
    // int L = days + 68569 + offset
    // int N = 4 * L / 146097
    // L = L - (146097 * N + 3) / 4
    // year = 4000 * (L + 1) / 1461001
    // L = L - 1461 * year / 4 + 31
    // month = 80 * L / 2447
    // dd = L - 2447 * month / 80
    // L = month / 11
    // month = month + 2 - 12 * L
    // year = 100 * (N - 49) + year + L
    // ------------------------------------------------------------------------
    function _daysToDate(uint _days) internal pure returns (uint year, uint month, uint day) {
        int __days = int(_days);

        int L = __days + 68569 + OFFSET19700101;
        int N = 4 * L / 146097;
        L = L - (146097 * N + 3) / 4;
        int _year = 4000 * (L + 1) / 1461001;
        L = L - 1461 * _year / 4 + 31;
        int _month = 80 * L / 2447;
        int _day = L - 2447 * _month / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        year = uint(_year);
        month = uint(_month);
        day = uint(_day);
    }

    function timestampFromDate(uint year, uint month, uint day) internal pure returns (uint timestamp) {
        timestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY;
    }
    function timestampFromDateTime(uint year, uint month, uint day, uint hour, uint minute, uint second) internal pure returns (uint timestamp) {
        timestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + hour * SECONDS_PER_HOUR + minute * SECONDS_PER_MINUTE + second;
    }
    function timestampToDate(uint timestamp) internal pure returns (uint year, uint month, uint day) {
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function timestampToDateTime(uint timestamp) internal pure returns (uint year, uint month, uint day, uint hour, uint minute, uint second) {
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        uint secs = timestamp % SECONDS_PER_DAY;
        hour = secs / SECONDS_PER_HOUR;
        secs = secs % SECONDS_PER_HOUR;
        minute = secs / SECONDS_PER_MINUTE;
        second = secs % SECONDS_PER_MINUTE;
    }

    function isValidDate(uint year, uint month, uint day) internal pure returns (bool valid) {
        if (year >= 1970 && month > 0 && month <= 12) {
            uint daysInMonth = _getDaysInMonth(year, month);
            if (day > 0 && day <= daysInMonth) {
                valid = true;
            }
        }
    }
    function isValidDateTime(uint year, uint month, uint day, uint hour, uint minute, uint second) internal pure returns (bool valid) {
        if (isValidDate(year, month, day)) {
            if (hour < 24 && minute < 60 && second < 60) {
                valid = true;
            }
        }
    }
    function isLeapYear(uint timestamp) internal pure returns (bool leapYear) {
        uint year;
        uint month;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        leapYear = _isLeapYear(year);
    }
    function _isLeapYear(uint year) internal pure returns (bool leapYear) {
        leapYear = ((year % 4 == 0) && (year % 100 != 0)) || (year % 400 == 0);
    }
    function isWeekDay(uint timestamp) internal pure returns (bool weekDay) {
        weekDay = getDayOfWeek(timestamp) <= DOW_FRI;
    }
    function isWeekEnd(uint timestamp) internal pure returns (bool weekEnd) {
        weekEnd = getDayOfWeek(timestamp) >= DOW_SAT;
    }
    function getDaysInMonth(uint timestamp) internal pure returns (uint daysInMonth) {
        uint year;
        uint month;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        daysInMonth = _getDaysInMonth(year, month);
    }
    function _getDaysInMonth(uint year, uint month) internal pure returns (uint daysInMonth) {
        if (month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) {
            daysInMonth = 31;
        } else if (month != 2) {
            daysInMonth = 30;
        } else {
            daysInMonth = _isLeapYear(year) ? 29 : 28;
        }
    }
    // 1 = Monday, 7 = Sunday
    function getDayOfWeek(uint timestamp) internal pure returns (uint dayOfWeek) {
        uint _days = timestamp / SECONDS_PER_DAY;
        dayOfWeek = (_days + 3) % 7 + 1;
    }

    function getYear(uint timestamp) internal pure returns (uint year) {
        uint month;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function getMonth(uint timestamp) internal pure returns (uint month) {
        uint year;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function getDay(uint timestamp) internal pure returns (uint day) {
        uint year;
        uint month;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function getHour(uint timestamp) internal pure returns (uint hour) {
        uint secs = timestamp % SECONDS_PER_DAY;
        hour = secs / SECONDS_PER_HOUR;
    }
    function getMinute(uint timestamp) internal pure returns (uint minute) {
        uint secs = timestamp % SECONDS_PER_HOUR;
        minute = secs / SECONDS_PER_MINUTE;
    }
    function getSecond(uint timestamp) internal pure returns (uint second) {
        second = timestamp % SECONDS_PER_MINUTE;
    }

    function addYears(uint timestamp, uint _years) internal pure returns (uint newTimestamp) {
        uint year;
        uint month;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        year += _years;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp >= timestamp);
    }
    function addMonths(uint timestamp, uint _months) internal pure returns (uint newTimestamp) {
        uint year;
        uint month;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        month += _months;
        year += (month - 1) / 12;
        month = (month - 1) % 12 + 1;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp >= timestamp);
    }
    function addDays(uint timestamp, uint _days) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _days * SECONDS_PER_DAY;
        require(newTimestamp >= timestamp);
    }
    function addHours(uint timestamp, uint _hours) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _hours * SECONDS_PER_HOUR;
        require(newTimestamp >= timestamp);
    }
    function addMinutes(uint timestamp, uint _minutes) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _minutes * SECONDS_PER_MINUTE;
        require(newTimestamp >= timestamp);
    }
    function addSeconds(uint timestamp, uint _seconds) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _seconds;
        require(newTimestamp >= timestamp);
    }

    function subYears(uint timestamp, uint _years) internal pure returns (uint newTimestamp) {
        uint year;
        uint month;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        year -= _years;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp <= timestamp);
    }
    function subMonths(uint timestamp, uint _months) internal pure returns (uint newTimestamp) {
        uint year;
        uint month;
        uint day;
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        uint yearMonth = year * 12 + (month - 1) - _months;
        year = yearMonth / 12;
        month = yearMonth % 12 + 1;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp <= timestamp);
    }
    function subDays(uint timestamp, uint _days) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _days * SECONDS_PER_DAY;
        require(newTimestamp <= timestamp);
    }
    function subHours(uint timestamp, uint _hours) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _hours * SECONDS_PER_HOUR;
        require(newTimestamp <= timestamp);
    }
    function subMinutes(uint timestamp, uint _minutes) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _minutes * SECONDS_PER_MINUTE;
        require(newTimestamp <= timestamp);
    }
    function subSeconds(uint timestamp, uint _seconds) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _seconds;
        require(newTimestamp <= timestamp);
    }

    function diffYears(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _years) {
        require(fromTimestamp <= toTimestamp);
        uint fromYear;
        uint fromMonth;
        uint fromDay;
        uint toYear;
        uint toMonth;
        uint toDay;
        (fromYear, fromMonth, fromDay) = _daysToDate(fromTimestamp / SECONDS_PER_DAY);
        (toYear, toMonth, toDay) = _daysToDate(toTimestamp / SECONDS_PER_DAY);
        _years = toYear - fromYear;
    }
    function diffMonths(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _months) {
        require(fromTimestamp <= toTimestamp);
        uint fromYear;
        uint fromMonth;
        uint fromDay;
        uint toYear;
        uint toMonth;
        uint toDay;
        (fromYear, fromMonth, fromDay) = _daysToDate(fromTimestamp / SECONDS_PER_DAY);
        (toYear, toMonth, toDay) = _daysToDate(toTimestamp / SECONDS_PER_DAY);
        _months = toYear * 12 + toMonth - fromYear * 12 - fromMonth;
    }
    function diffDays(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _days) {
        require(fromTimestamp <= toTimestamp);
        _days = (toTimestamp - fromTimestamp) / SECONDS_PER_DAY;
    }
    function diffHours(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _hours) {
        require(fromTimestamp <= toTimestamp);
        _hours = (toTimestamp - fromTimestamp) / SECONDS_PER_HOUR;
    }
    function diffMinutes(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _minutes) {
        require(fromTimestamp <= toTimestamp);
        _minutes = (toTimestamp - fromTimestamp) / SECONDS_PER_MINUTE;
    }
    function diffSeconds(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _seconds) {
        require(fromTimestamp <= toTimestamp);
        _seconds = toTimestamp - fromTimestamp;
    }
}

pragma solidity ^0.6.0;

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        // Check the signature length
        if (signature.length != 65) {
            revert("ECDSA: invalid signature length");
        }

        // Divide the signature in r, s and v variables
        bytes32 r;
        bytes32 s;
        uint8 v;

        // ecrecover takes the signature parameters, and the only way to get them
        // currently is to use assembly.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (281): 0 < s < secp256k1n ÷ 2 + 1, and for v in (282): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert("ECDSA: invalid signature 's' value");
        }

        if (v != 27 && v != 28) {
            revert("ECDSA: invalid signature 'v' value");
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        require(signer != address(0), "ECDSA: invalid signature");

        return signer;
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from a `hash`. This
     * replicates the behavior of the
     * https://github.com/ethereum/wiki/wiki/JSON-RPC#eth_sign[`eth_sign`]
     * JSON-RPC method.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}

pragma solidity ^0.6.0;

import "../utils/EnumerableSet.sol";
import "../utils/Address.sol";
import "../GSN/Context.sol";
import "../Initializable.sol";

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms.
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
 *     require(hasRole(MY_ROLE, _msgSender()));
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
 */
abstract contract AccessControlUpgradeSafe is Initializable, ContextUpgradeSafe {
    function __AccessControl_init() internal initializer {
        __Context_init_unchained();
        __AccessControl_init_unchained();
    }

    function __AccessControl_init_unchained() internal initializer {


    }

    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;

    struct RoleData {
        EnumerableSet.AddressSet members;
        bytes32 adminRole;
    }

    mapping (bytes32 => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

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
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role].members.contains(account);
    }

    /**
     * @dev Returns the number of accounts that have `role`. Can be used
     * together with {getRoleMember} to enumerate all bearers of a role.
     */
    function getRoleMemberCount(bytes32 role) public view returns (uint256) {
        return _roles[role].members.length();
    }

    /**
     * @dev Returns one of the accounts that have `role`. `index` must be a
     * value between 0 and {getRoleMemberCount}, non-inclusive.
     *
     * Role bearers are not sorted in any particular way, and their ordering may
     * change at any point.
     *
     * WARNING: When using {getRoleMember} and {getRoleMemberCount}, make sure
     * you perform all queries on the same block. See the following
     * https://forum.openzeppelin.com/t/iterating-over-elements-on-enumerableset-in-openzeppelin-contracts/2296[forum post]
     * for more information.
     */
    function getRoleMember(bytes32 role, uint256 index) public view returns (address) {
        return _roles[role].members.at(index);
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view returns (bytes32) {
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
    function grantRole(bytes32 role, address account) public virtual {
        require(hasRole(_roles[role].adminRole, _msgSender()), "AccessControl: sender must be an admin to grant");

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
    function revokeRole(bytes32 role, address account) public virtual {
        require(hasRole(_roles[role].adminRole, _msgSender()), "AccessControl: sender must be an admin to revoke");

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
    function renounceRole(bytes32 role, address account) public virtual {
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
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        _roles[role].adminRole = adminRole;
    }

    function _grantRole(bytes32 role, address account) private {
        if (_roles[role].members.add(account)) {
            emit RoleGranted(role, account, _msgSender());
        }
    }

    function _revokeRole(bytes32 role, address account) private {
        if (_roles[role].members.remove(account)) {
            emit RoleRevoked(role, account, _msgSender());
        }
    }

    uint256[49] private __gap;
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    ContractManager.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/Address.sol";

import "./utils/StringUtils.sol";


/**
 * @title ContractManager
 * @dev Contract contains the actual current mapping from contract IDs
 * (in the form of human-readable strings) to addresses.
 */
contract ContractManager is OwnableUpgradeSafe {
    using StringUtils for string;
    using Address for address;

    string public constant BOUNTY = "Bounty";
    string public constant CONSTANTS_HOLDER = "ConstantsHolder";
    string public constant DELEGATION_PERIOD_MANAGER = "DelegationPeriodManager";
    string public constant PUNISHER = "Punisher";
    string public constant SKALE_TOKEN = "SkaleToken";
    string public constant TIME_HELPERS = "TimeHelpers";
    string public constant TOKEN_STATE = "TokenState";
    string public constant VALIDATOR_SERVICE = "ValidatorService";

    // mapping of actual smart contracts addresses
    mapping (bytes32 => address) public contracts;

    /**
     * @dev Emitted when contract is upgraded.
     */
    event ContractUpgraded(string contractsName, address contractsAddress);

    function initialize() external initializer {
        OwnableUpgradeSafe.__Ownable_init();
    }

    /**
     * @dev Allows the Owner to add contract to mapping of contract addresses.
     * 
     * Emits a {ContractUpgraded} event.
     * 
     * Requirements:
     * 
     * - New address is non-zero.
     * - Contract is not already added.
     * - Contract address contains code.
     */
    function setContractsAddress(string calldata contractsName, address newContractsAddress) external onlyOwner {
        // check newContractsAddress is not equal to zero
        require(newContractsAddress != address(0), "New address is equal zero");
        // create hash of contractsName
        bytes32 contractId = keccak256(abi.encodePacked(contractsName));
        // check newContractsAddress is not equal the previous contract's address
        require(contracts[contractId] != newContractsAddress, "Contract is already added");
        require(newContractsAddress.isContract(), "Given contract address does not contain code");
        // add newContractsAddress to mapping of actual contract addresses
        contracts[contractId] = newContractsAddress;
        emit ContractUpgraded(contractsName, newContractsAddress);
    }

    /**
     * @dev Returns contract address.
     * 
     * Requirements:
     * 
     * - Contract must exist.
     */
    function getDelegationPeriodManager() external view returns (address) {
        return getContract(DELEGATION_PERIOD_MANAGER);
    }

    function getBounty() external view returns (address) {
        return getContract(BOUNTY);
    }

    function getValidatorService() external view returns (address) {
        return getContract(VALIDATOR_SERVICE);
    }

    function getTimeHelpers() external view returns (address) {
        return getContract(TIME_HELPERS);
    }

    function getConstantsHolder() external view returns (address) {
        return getContract(CONSTANTS_HOLDER);
    }

    function getSkaleToken() external view returns (address) {
        return getContract(SKALE_TOKEN);
    }

    function getTokenState() external view returns (address) {
        return getContract(TOKEN_STATE);
    }

    function getPunisher() external view returns (address) {
        return getContract(PUNISHER);
    }

    function getContract(string memory name) public view returns (address contractAddress) {
        contractAddress = contracts[keccak256(abi.encodePacked(name))];
        if (contractAddress == address(0)) {
            revert(name.strConcat(" contract has not been found"));
        }
    }
}

pragma solidity ^0.6.0;

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
 * As of v3.0.0, only sets of type `address` (`AddressSet`) and `uint256`
 * (`UintSet`) are supported.
 */
library EnumerableSet {
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
        return _add(set._inner, bytes32(uint256(value)));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(value)));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(value)));
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
        return address(uint256(_at(set._inner, index)));
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

pragma solidity ^0.6.2;

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
        // According to EIP-1052, 0x0 is the value returned for not-yet created accounts
        // and 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 is returned
        // for accounts without code, i.e. `keccak256('')`
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly { codehash := extcodehash(account) }
        return (codehash != accountHash && codehash != 0x0);
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
}

pragma solidity ^0.6.0;
import "../Initializable.sol";

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
contract ContextUpgradeSafe is Initializable {
    // Empty internal constructor, to prevent people from mistakenly deploying
    // an instance of this contract, which should be used via inheritance.

    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {


    }


    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }

    uint256[50] private __gap;
}

pragma solidity >=0.4.24 <0.7.0;


/**
 * @title Initializable
 *
 * @dev Helper contract to support initializer functions. To use it, replace
 * the constructor with a function that has the `initializer` modifier.
 * WARNING: Unlike constructors, initializer functions must be manually
 * invoked. This applies both to deploying an Initializable contract, as well
 * as extending an Initializable contract via inheritance.
 * WARNING: When used with inheritance, manual care must be taken to not invoke
 * a parent initializer twice, or ensure that all initializers are idempotent,
 * because this is not dealt with automatically as with constructors.
 */
contract Initializable {

  /**
   * @dev Indicates that the contract has been initialized.
   */
  bool private initialized;

  /**
   * @dev Indicates that the contract is in the process of being initialized.
   */
  bool private initializing;

  /**
   * @dev Modifier to use in the initializer function of a contract.
   */
  modifier initializer() {
    require(initializing || isConstructor() || !initialized, "Contract instance has already been initialized");

    bool isTopLevelCall = !initializing;
    if (isTopLevelCall) {
      initializing = true;
      initialized = true;
    }

    _;

    if (isTopLevelCall) {
      initializing = false;
    }
  }

  /// @dev Returns true if and only if the function is running in the constructor
  function isConstructor() private view returns (bool) {
    // extcodesize checks the size of the code stored in an address, and
    // address returns the current address. Since the code is still not
    // deployed when running a constructor, any checks on its code size will
    // yield zero, making it an effective way to detect if a contract is
    // under construction or not.
    address self = address(this);
    uint256 cs;
    assembly { cs := extcodesize(self) }
    return cs == 0;
  }

  // Reserved storage space to allow for layout changes in the future.
  uint256[50] private ______gap;
}

pragma solidity ^0.6.0;

import "../GSN/Context.sol";
import "../Initializable.sol";
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
contract OwnableUpgradeSafe is Initializable, ContextUpgradeSafe {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */

    function __Ownable_init() internal initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal initializer {


        address msgSender = _msgSender();
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
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
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

    uint256[49] private __gap;
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    StringUtils.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";


library StringUtils {
    using SafeMath for uint;

    function strConcat(string memory a, string memory b) internal pure returns (string memory) {
        bytes memory _ba = bytes(a);
        bytes memory _bb = bytes(b);

        string memory ab = new string(_ba.length.add(_bb.length));
        bytes memory strBytes = bytes(ab);
        uint k = 0;
        uint i = 0;
        for (i = 0; i < _ba.length; i++) {
            strBytes[k++] = _ba[i];
        }
        for (i = 0; i < _bb.length; i++) {
            strBytes[k++] = _bb[i];
        }
        return string(strBytes);
    }
}

pragma solidity ^0.6.0;


/**
 * @dev Wrappers over Solidity's uintXX casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 *
 * Can be combined with {SafeMath} to extend it to smaller types, by performing
 * all math on `uint256` and then downcasting.
 */
library SafeCast {

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

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SegmentTree.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

/**
 * @title Random
 * @dev The library for generating of pseudo random numbers
 */
library Random {
    using SafeMath for uint;

    struct RandomGenerator {
        uint seed;
    }

    /**
     * @dev Create an instance of RandomGenerator
     */
    function create(uint seed) internal pure returns (RandomGenerator memory) {
        return RandomGenerator({seed: seed});
    }

    function createFromEntropy(bytes memory entropy) internal pure returns (RandomGenerator memory) {
        return create(uint(keccak256(entropy)));
    }

    /**
     * @dev Generates random value
     */
    function random(RandomGenerator memory self) internal pure returns (uint) {
        self.seed = uint(sha256(abi.encodePacked(self.seed)));
        return self.seed;
    }

    /**
     * @dev Generates random value in range [0, max)
     */
    function random(RandomGenerator memory self, uint max) internal pure returns (uint) {
        assert(max > 0);
        uint maxRand = uint(-1).sub(uint(-1).mod(max));
        if (uint(-1).sub(maxRand) == max.sub(1)) {
            return random(self).mod(max);
        } else {
            uint rand = random(self);
            while (rand >= maxRand) {
                rand = random(self);
            }
            return rand.mod(max);
        }
    }

    /**
     * @dev Generates random value in range [min, max)
     */
    function random(RandomGenerator memory self, uint min, uint max) internal pure returns (uint) {
        assert(min < max);
        return min.add(random(self, max.sub(min)));
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SegmentTree.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Artem Payvin
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

import "./Random.sol";

/**
 * @title SegmentTree
 * @dev This library implements segment tree data structure
 * 
 * Segment tree allows effectively calculate sum of elements in sub arrays
 * by storing some amount of additional data.
 * 
 * IMPORTANT: Provided implementation assumes that arrays is indexed from 1 to n.
 * Size of initial array always must be power of 2
 * 
 * Example:
 *
 * Array:
 * +---+---+---+---+---+---+---+---+
 * | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
 * +---+---+---+---+---+---+---+---+
 *
 * Segment tree structure:
 * +-------------------------------+
 * |               36              |
 * +---------------+---------------+
 * |       10      |       26      |
 * +-------+-------+-------+-------+
 * |   3   |   7   |   11  |   15  |
 * +---+---+---+---+---+---+---+---+
 * | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
 * +---+---+---+---+---+---+---+---+
 *
 * How the segment tree is stored in an array:
 * +----+----+----+---+---+----+----+---+---+---+---+---+---+---+---+
 * | 36 | 10 | 26 | 3 | 7 | 11 | 15 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
 * +----+----+----+---+---+----+----+---+---+---+---+---+---+---+---+
 */
library SegmentTree {
    using Random for Random.RandomGenerator;
    using SafeMath for uint;    

    struct Tree {
        uint[] tree;
    }

    /**
     * @dev Allocates storage for segment tree of `size` elements
     * 
     * Requirements:
     * 
     * - `size` must be greater than 0
     * - `size` must be power of 2
     */
    function create(Tree storage segmentTree, uint size) external {
        require(size > 0, "Size can't be 0");
        require(size & size.sub(1) == 0, "Size is not power of 2");
        segmentTree.tree = new uint[](size.mul(2).sub(1));
    }

    /**
     * @dev Adds `delta` to element of segment tree at `place`
     * 
     * Requirements:
     * 
     * - `place` must be in range [1, size]
     */
    function addToPlace(Tree storage self, uint place, uint delta) external {
        require(_correctPlace(self, place), "Incorrect place");
        uint leftBound = 1;
        uint rightBound = getSize(self);
        uint step = 1;
        self.tree[0] = self.tree[0].add(delta);
        while(leftBound < rightBound) {
            uint middle = leftBound.add(rightBound).div(2);
            if (place > middle) {
                leftBound = middle.add(1);
                step = step.add(step).add(1);
            } else {
                rightBound = middle;
                step = step.add(step);
            }
            self.tree[step.sub(1)] = self.tree[step.sub(1)].add(delta);
        }
    }

    /**
     * @dev Subtracts `delta` from element of segment tree at `place`
     * 
     * Requirements:
     * 
     * - `place` must be in range [1, size]
     * - initial value of target element must be not less than `delta`
     */
    function removeFromPlace(Tree storage self, uint place, uint delta) external {
        require(_correctPlace(self, place), "Incorrect place");
        uint leftBound = 1;
        uint rightBound = getSize(self);
        uint step = 1;
        self.tree[0] = self.tree[0].sub(delta);
        while(leftBound < rightBound) {
            uint middle = leftBound.add(rightBound).div(2);
            if (place > middle) {
                leftBound = middle.add(1);
                step = step.add(step).add(1);
            } else {
                rightBound = middle;
                step = step.add(step);
            }
            self.tree[step.sub(1)] = self.tree[step.sub(1)].sub(delta);
        }
    }

    /**
     * @dev Adds `delta` to element of segment tree at `toPlace`
     * and subtracts `delta` from element at `fromPlace`
     * 
     * Requirements:
     * 
     * - `fromPlace` must be in range [1, size]
     * - `toPlace` must be in range [1, size]
     * - initial value of element at `fromPlace` must be not less than `delta`
     */
    function moveFromPlaceToPlace(
        Tree storage self,
        uint fromPlace,
        uint toPlace,
        uint delta
    )
        external
    {
        require(_correctPlace(self, fromPlace) && _correctPlace(self, toPlace), "Incorrect place");
        uint leftBound = 1;
        uint rightBound = getSize(self);
        uint step = 1;
        uint middle = leftBound.add(rightBound).div(2);
        uint fromPlaceMove = fromPlace > toPlace ? toPlace : fromPlace;
        uint toPlaceMove = fromPlace > toPlace ? fromPlace : toPlace;
        while (toPlaceMove <= middle || middle < fromPlaceMove) {
            if (middle < fromPlaceMove) {
                leftBound = middle.add(1);
                step = step.add(step).add(1);
            } else {
                rightBound = middle;
                step = step.add(step);
            }
            middle = leftBound.add(rightBound).div(2);
        }

        uint leftBoundMove = leftBound;
        uint rightBoundMove = rightBound;
        uint stepMove = step;
        while(leftBoundMove < rightBoundMove && leftBound < rightBound) {
            uint middleMove = leftBoundMove.add(rightBoundMove).div(2);
            if (fromPlace > middleMove) {
                leftBoundMove = middleMove.add(1);
                stepMove = stepMove.add(stepMove).add(1);
            } else {
                rightBoundMove = middleMove;
                stepMove = stepMove.add(stepMove);
            }
            self.tree[stepMove.sub(1)] = self.tree[stepMove.sub(1)].sub(delta);
            middle = leftBound.add(rightBound).div(2);
            if (toPlace > middle) {
                leftBound = middle.add(1);
                step = step.add(step).add(1);
            } else {
                rightBound = middle;
                step = step.add(step);
            }
            self.tree[step.sub(1)] = self.tree[step.sub(1)].add(delta);
        }
    }

    /**
     * @dev Returns random position in range [`place`, size]
     * with probability proportional to value stored at this position.
     * If all element in range are 0 returns 0
     * 
     * Requirements:
     * 
     * - `place` must be in range [1, size]
     */
    function getRandomNonZeroElementFromPlaceToLast(
        Tree storage self,
        uint place,
        Random.RandomGenerator memory randomGenerator
    )
        external
        view
        returns (uint)
    {
        require(_correctPlace(self, place), "Incorrect place");

        uint vertex = 1;
        uint leftBound = 0;
        uint rightBound = getSize(self);
        uint currentFrom = place.sub(1);
        uint currentSum = sumFromPlaceToLast(self, place);
        if (currentSum == 0) {
            return 0;
        }
        while(leftBound.add(1) < rightBound) {
            if (_middle(leftBound, rightBound) <= currentFrom) {
                vertex = _right(vertex);
                leftBound = _middle(leftBound, rightBound);
            } else {
                uint rightSum = self.tree[_right(vertex).sub(1)];
                uint leftSum = currentSum.sub(rightSum);
                if (Random.random(randomGenerator, currentSum) < leftSum) {
                    // go left
                    vertex = _left(vertex);
                    rightBound = _middle(leftBound, rightBound);
                    currentSum = leftSum;
                } else {
                    // go right
                    vertex = _right(vertex);
                    leftBound = _middle(leftBound, rightBound);
                    currentFrom = leftBound;
                    currentSum = rightSum;
                }
            }
        }
        return leftBound.add(1);
    }

    /**
     * @dev Returns sum of elements in range [`place`, size]
     * 
     * Requirements:
     * 
     * - `place` must be in range [1, size]
     */
    function sumFromPlaceToLast(Tree storage self, uint place) public view returns (uint sum) {
        require(_correctPlace(self, place), "Incorrect place");
        if (place == 1) {
            return self.tree[0];
        }
        uint leftBound = 1;
        uint rightBound = getSize(self);
        uint step = 1;
        while(leftBound < rightBound) {
            uint middle = leftBound.add(rightBound).div(2);
            if (place > middle) {
                leftBound = middle.add(1);
                step = step.add(step).add(1);
            } else {
                rightBound = middle;
                step = step.add(step);
                sum = sum.add(self.tree[step]);
            }
        }
        sum = sum.add(self.tree[step.sub(1)]);
    }

    /**
     * @dev Returns amount of elements in segment tree
     */
    function getSize(Tree storage segmentTree) internal view returns (uint) {
        if (segmentTree.tree.length > 0) {
            return segmentTree.tree.length.div(2).add(1);
        } else {
            return 0;
        }
    }

    /**
     * @dev Checks if `place` is valid position in segment tree
     */
    function _correctPlace(Tree storage self, uint place) private view returns (bool) {
        return place >= 1 && place <= getSize(self);
    }

    /**
     * @dev Calculates index of left child of the vertex
     */
    function _left(uint vertex) private pure returns (uint) {
        return vertex.mul(2);
    }

    /**
     * @dev Calculates index of right child of the vertex
     */
    function _right(uint vertex) private pure returns (uint) {
        return vertex.mul(2).add(1);
    }

    /**
     * @dev Calculates arithmetical mean of 2 numbers
     */
    function _middle(uint left, uint right) private pure returns (uint) {
        return left.add(right).div(2);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    ILocker.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

/**
 * @dev Interface of the Locker functions.
 */
interface ILocker {
    /**
     * @dev Returns and updates the total amount of locked tokens of a given 
     * `holder`.
     */
    function getAndUpdateLockedAmount(address wallet) external returns (uint);

    /**
     * @dev Returns and updates the total non-transferrable and un-delegatable
     * amount of a given `holder`.
     */
    function getAndUpdateForbiddenForDelegationAmount(address wallet) external returns (uint);
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    NodesMock.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/
pragma solidity 0.6.10;

import "../BountyV2.sol";
import "../Permissions.sol";


contract NodesMock is Permissions {
    uint public nodesCount = 0;
    uint public nodesLeft = 0;
    //     nodeId => timestamp
    mapping (uint => uint) public lastRewardDate;
    //     nodeId => left
    mapping (uint => bool) public nodeLeft;
    //     nodeId => validatorId
    mapping (uint => uint) public owner;
    
    function registerNodes(uint amount, uint validatorId) external {
        for (uint nodeId = nodesCount; nodeId < nodesCount + amount; ++nodeId) {
            lastRewardDate[nodeId] = now;
            owner[nodeId] = validatorId;
        }
        nodesCount += amount;
    }
    function removeNode(uint nodeId) external {
        ++nodesLeft;
        nodeLeft[nodeId] = true;
    }
    function changeNodeLastRewardDate(uint nodeId) external {
        lastRewardDate[nodeId] = now;
    }
    function getNodeLastRewardDate(uint nodeIndex) external view returns (uint) {
        require(nodeIndex < nodesCount, "Node does not exist");
        return lastRewardDate[nodeIndex];
    }
    function isNodeLeft(uint nodeId) external view returns (bool) {
        return nodeLeft[nodeId];
    }
    function getNumberOnlineNodes() external view returns (uint) {
        return nodesCount.sub(nodesLeft);
    }
    function checkPossibilityToMaintainNode(uint /* validatorId */, uint /* nodeIndex */) external pure returns (bool) {
        return true;
    }
    function getValidatorId(uint nodeId) external view returns (uint) {
        return owner[nodeId];
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleManagerMock.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777.sol";

import "../interfaces/IMintableToken.sol";
import "../Permissions.sol";


contract SkaleManagerMock is Permissions, IERC777Recipient {

    IERC1820Registry private _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    bytes32 constant public ADMIN_ROLE = keccak256("ADMIN_ROLE");

    constructor (address contractManagerAddress) public {
        Permissions.initialize(contractManagerAddress);
        _erc1820.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
    }

    function payBounty(uint validatorId, uint amount) external {
        IERC777 skaleToken = IERC777(contractManager.getContract("SkaleToken"));
        require(IMintableToken(address(skaleToken)).mint(address(this), amount, "", ""), "Token was not minted");
        require(
            IMintableToken(address(skaleToken))
                .mint(contractManager.getContract("Distributor"), amount, abi.encode(validatorId), ""),
            "Token was not minted"
        );
    }

    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    )
        external override allow("SkaleToken")
        // solhint-disable-next-line no-empty-blocks
    {
        
    }
}

pragma solidity ^0.6.0;

/**
 * @dev Interface of the global ERC1820 Registry, as defined in the
 * https://eips.ethereum.org/EIPS/eip-1820[EIP]. Accounts may register
 * implementers for interfaces in this registry, as well as query support.
 *
 * Implementers may be shared by multiple accounts, and can also implement more
 * than a single interface for each account. Contracts can implement interfaces
 * for themselves, but externally-owned accounts (EOA) must delegate this to a
 * contract.
 *
 * {IERC165} interfaces can also be queried via the registry.
 *
 * For an in-depth explanation and source code analysis, see the EIP text.
 */
interface IERC1820Registry {
    /**
     * @dev Sets `newManager` as the manager for `account`. A manager of an
     * account is able to set interface implementers for it.
     *
     * By default, each account is its own manager. Passing a value of `0x0` in
     * `newManager` will reset the manager to this initial state.
     *
     * Emits a {ManagerChanged} event.
     *
     * Requirements:
     *
     * - the caller must be the current manager for `account`.
     */
    function setManager(address account, address newManager) external;

    /**
     * @dev Returns the manager for `account`.
     *
     * See {setManager}.
     */
    function getManager(address account) external view returns (address);

    /**
     * @dev Sets the `implementer` contract as ``account``'s implementer for
     * `interfaceHash`.
     *
     * `account` being the zero address is an alias for the caller's address.
     * The zero address can also be used in `implementer` to remove an old one.
     *
     * See {interfaceHash} to learn how these are created.
     *
     * Emits an {InterfaceImplementerSet} event.
     *
     * Requirements:
     *
     * - the caller must be the current manager for `account`.
     * - `interfaceHash` must not be an {IERC165} interface id (i.e. it must not
     * end in 28 zeroes).
     * - `implementer` must implement {IERC1820Implementer} and return true when
     * queried for support, unless `implementer` is the caller. See
     * {IERC1820Implementer-canImplementInterfaceForAddress}.
     */
    function setInterfaceImplementer(address account, bytes32 interfaceHash, address implementer) external;

    /**
     * @dev Returns the implementer of `interfaceHash` for `account`. If no such
     * implementer is registered, returns the zero address.
     *
     * If `interfaceHash` is an {IERC165} interface id (i.e. it ends with 28
     * zeroes), `account` will be queried for support of it.
     *
     * `account` being the zero address is an alias for the caller's address.
     */
    function getInterfaceImplementer(address account, bytes32 interfaceHash) external view returns (address);

    /**
     * @dev Returns the interface hash for an `interfaceName`, as defined in the
     * corresponding
     * https://eips.ethereum.org/EIPS/eip-1820#interface-name[section of the EIP].
     */
    function interfaceHash(string calldata interfaceName) external pure returns (bytes32);

    /**
     *  @notice Updates the cache with whether the contract implements an ERC165 interface or not.
     *  @param account Address of the contract for which to update the cache.
     *  @param interfaceId ERC165 interface for which to update the cache.
     */
    function updateERC165Cache(address account, bytes4 interfaceId) external;

    /**
     *  @notice Checks whether a contract implements an ERC165 interface or not.
     *  If the result is not cached a direct lookup on the contract address is performed.
     *  If the result is not cached or the cached value is out-of-date, the cache MUST be updated manually by calling
     *  {updateERC165Cache} with the contract address.
     *  @param account Address of the contract to check.
     *  @param interfaceId ERC165 interface to check.
     *  @return True if `account` implements `interfaceId`, false otherwise.
     */
    function implementsERC165Interface(address account, bytes4 interfaceId) external view returns (bool);

    /**
     *  @notice Checks whether a contract implements an ERC165 interface or not without using nor updating the cache.
     *  @param account Address of the contract to check.
     *  @param interfaceId ERC165 interface to check.
     *  @return True if `account` implements `interfaceId`, false otherwise.
     */
    function implementsERC165InterfaceNoCache(address account, bytes4 interfaceId) external view returns (bool);

    event InterfaceImplementerSet(address indexed account, bytes32 indexed interfaceHash, address indexed implementer);

    event ManagerChanged(address indexed account, address indexed newManager);
}

pragma solidity ^0.6.0;

/**
 * @dev Interface of the ERC777TokensRecipient standard as defined in the EIP.
 *
 * Accounts can be notified of {IERC777} tokens being sent to them by having a
 * contract implement this interface (contract holders can be their own
 * implementer) and registering it on the
 * https://eips.ethereum.org/EIPS/eip-1820[ERC1820 global registry].
 *
 * See {IERC1820Registry} and {ERC1820Implementer}.
 */
interface IERC777Recipient {
    /**
     * @dev Called by an {IERC777} token contract whenever tokens are being
     * moved or created into a registered account (`to`). The type of operation
     * is conveyed by `from` being the zero address or not.
     *
     * This call occurs _after_ the token contract's state is updated, so
     * {IERC777-balanceOf}, etc., can be used to query the post-operation state.
     *
     * This function may revert to prevent the operation from being executed.
     */
    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external;
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    IMintableToken.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

interface IMintableToken {
    function mint(
        address account,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    )
        external
        returns (bool);
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleToken.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./thirdparty/openzeppelin/ERC777.sol";

import "./Permissions.sol";
import "./interfaces/delegation/IDelegatableToken.sol";
import "./interfaces/IMintableToken.sol";
import "./delegation/Punisher.sol";
import "./delegation/TokenState.sol";


/**
 * @title SkaleToken
 * @dev Contract defines the SKALE token and is based on ERC777 token
 * implementation.
 */
contract SkaleToken is ERC777, Permissions, ReentrancyGuard, IDelegatableToken, IMintableToken {
    using SafeMath for uint;

    string public constant NAME = "SKALE";

    string public constant SYMBOL = "SKL";

    uint public constant DECIMALS = 18;

    uint public constant CAP = 7 * 1e9 * (10 ** DECIMALS); // the maximum amount of tokens that can ever be created

    constructor(address contractsAddress, address[] memory defOps) public
    ERC777("SKALE", "SKL", defOps)
    {
        Permissions.initialize(contractsAddress);
    }

    /**
     * @dev Allows Owner or SkaleManager to mint an amount of tokens and 
     * transfer minted tokens to a specified address.
     * 
     * Returns whether the operation is successful.
     * 
     * Requirements:
     * 
     * - Mint must not exceed the total supply.
     */
    function mint(
        address account,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    )
        external
        override
        allow("SkaleManager")
        //onlyAuthorized
        returns (bool)
    {
        require(amount <= CAP.sub(totalSupply()), "Amount is too big");
        _mint(
            account,
            amount,
            userData,
            operatorData
        );

        return true;
    }

    /**
     * @dev See {IDelegatableToken-getAndUpdateDelegatedAmount}.
     */
    function getAndUpdateDelegatedAmount(address wallet) external override returns (uint) {
        return DelegationController(contractManager.getContract("DelegationController"))
            .getAndUpdateDelegatedAmount(wallet);
    }

    /**
     * @dev See {IDelegatableToken-getAndUpdateSlashedAmount}.
     */
    function getAndUpdateSlashedAmount(address wallet) external override returns (uint) {
        return Punisher(contractManager.getContract("Punisher")).getAndUpdateLockedAmount(wallet);
    }

    /**
     * @dev See {IDelegatableToken-getAndUpdateLockedAmount}.
     */
    function getAndUpdateLockedAmount(address wallet) public override returns (uint) {
        return TokenState(contractManager.getContract("TokenState")).getAndUpdateLockedAmount(wallet);
    }

    // internal

    function _beforeTokenTransfer(
        address, // operator
        address from,
        address, // to
        uint256 tokenId)
        internal override
    {
        uint locked = getAndUpdateLockedAmount(from);
        if (locked > 0) {
            require(balanceOf(from) >= locked.add(tokenId), "Token should be unlocked for transferring");
        }
    }

    function _callTokensToSend(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    ) internal override nonReentrant {
        super._callTokensToSend(operator, from, to, amount, userData, operatorData);
    }

    function _callTokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData,
        bool requireReceptionAck
    ) internal override nonReentrant {
        super._callTokensReceived(operator, from, to, amount, userData, operatorData, requireReceptionAck);
    }

    // we have to override _msgData() and _msgSender() functions because of collision in Context and ContextUpgradeSafe

    function _msgData() internal view override(Context, ContextUpgradeSafe) returns (bytes memory) {
        return Context._msgData();
    }

    function _msgSender() internal view override(Context, ContextUpgradeSafe) returns (address payable) {
        return Context._msgSender();
    }
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

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Sender.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/math/SafeMath.sol"; Removed by SKALE
// import "@openzeppelin/contracts/utils/Address.sol"; Removed by SKALE
import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";

/* Added by SKALE */
import "../../Permissions.sol";
/* End of added by SKALE */

/**
 * @dev Implementation of the {IERC777} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * Support for ERC20 is included in this contract, as specified by the EIP: both
 * the ERC777 and ERC20 interfaces can be safely used when interacting with it.
 * Both {IERC777-Sent} and {IERC20-Transfer} events are emitted on token
 * movements.
 *
 * Additionally, the {IERC777-granularity} value is hard-coded to `1`, meaning that there
 * are no special restrictions in the amount of tokens that created, moved, or
 * destroyed. This makes integration with ERC20 applications seamless.
 */
contract ERC777 is Context, IERC777, IERC20 {
    using SafeMath for uint256;
    using Address for address;

    IERC1820Registry constant internal _ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    mapping(address => uint256) private _balances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    // We inline the result of the following hashes because Solidity doesn't resolve them at compile time.
    // See https://github.com/ethereum/solidity/issues/4024.

    // keccak256("ERC777TokensSender")
    bytes32 constant private _TOKENS_SENDER_INTERFACE_HASH =
        0x29ddb589b1fb5fc7cf394961c1adf5f8c6454761adf795e67fe149f658abe895;

    // keccak256("ERC777TokensRecipient")
    bytes32 constant private _TOKENS_RECIPIENT_INTERFACE_HASH =
        0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b;

    // This isn't ever read from - it's only used to respond to the defaultOperators query.
    address[] private _defaultOperatorsArray;

    // Immutable, but accounts may revoke them (tracked in __revokedDefaultOperators).
    mapping(address => bool) private _defaultOperators;

    // For each account, a mapping of its operators and revoked default operators.
    mapping(address => mapping(address => bool)) private _operators;
    mapping(address => mapping(address => bool)) private _revokedDefaultOperators;

    // ERC20-allowances
    mapping (address => mapping (address => uint256)) private _allowances;

    /**
     * @dev `defaultOperators` may be an empty array.
     */
    constructor(
        string memory name,
        string memory symbol,
        address[] memory defaultOperators
    ) public {
        _name = name;
        _symbol = symbol;

        _defaultOperatorsArray = defaultOperators;
        for (uint256 i = 0; i < _defaultOperatorsArray.length; i++) {
            _defaultOperators[_defaultOperatorsArray[i]] = true;
        }

        // register interfaces
        _ERC1820_REGISTRY.setInterfaceImplementer(address(this), keccak256("ERC777Token"), address(this));
        _ERC1820_REGISTRY.setInterfaceImplementer(address(this), keccak256("ERC20Token"), address(this));
    }

    /**
     * @dev See {IERC777-name}.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * @dev See {IERC777-symbol}.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev See {ERC20-decimals}.
     *
     * Always returns 18, as per the
     * [ERC777 EIP](https://eips.ethereum.org/EIPS/eip-777#backward-compatibility).
     */
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC777-granularity}.
     *
     * This implementation always returns `1`.
     */
    function granularity() public view override returns (uint256) {
        return 1;
    }

    /**
     * @dev See {IERC777-totalSupply}.
     */
    function totalSupply() public view override(IERC20, IERC777) returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Returns the amount of tokens owned by an account (`tokenHolder`).
     */
    function balanceOf(address tokenHolder) public view override(IERC20, IERC777) returns (uint256) {
        return _balances[tokenHolder];
    }

    /**
     * @dev See {IERC777-send}.
     *
     * Also emits a {IERC20-Transfer} event for ERC20 compatibility.
     */
    function send(address recipient, uint256 amount, bytes memory data) public override  {
        _send(_msgSender(), recipient, amount, data, "", true);
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Unlike `send`, `recipient` is _not_ required to implement the {IERC777Recipient}
     * interface if it is a contract.
     *
     * Also emits a {Sent} event.
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        require(recipient != address(0), "ERC777: transfer to the zero address");

        address from = _msgSender();

        _callTokensToSend(from, from, recipient, amount, "", "");

        _move(from, from, recipient, amount, "", "");

        _callTokensReceived(from, from, recipient, amount, "", "", false);

        return true;
    }

    /**
     * @dev See {IERC777-burn}.
     *
     * Also emits a {IERC20-Transfer} event for ERC20 compatibility.
     */
    function burn(uint256 amount, bytes memory data) public override  {
        _burn(_msgSender(), amount, data, "");
    }

    /**
     * @dev See {IERC777-isOperatorFor}.
     */
    function isOperatorFor(
        address operator,
        address tokenHolder
    ) public view override returns (bool) {
        return operator == tokenHolder ||
            (_defaultOperators[operator] && !_revokedDefaultOperators[tokenHolder][operator]) ||
            _operators[tokenHolder][operator];
    }

    /**
     * @dev See {IERC777-authorizeOperator}.
     */
    function authorizeOperator(address operator) public override  {
        require(_msgSender() != operator, "ERC777: authorizing self as operator");

        if (_defaultOperators[operator]) {
            delete _revokedDefaultOperators[_msgSender()][operator];
        } else {
            _operators[_msgSender()][operator] = true;
        }

        emit AuthorizedOperator(operator, _msgSender());
    }

    /**
     * @dev See {IERC777-revokeOperator}.
     */
    function revokeOperator(address operator) public override  {
        require(operator != _msgSender(), "ERC777: revoking self as operator");

        if (_defaultOperators[operator]) {
            _revokedDefaultOperators[_msgSender()][operator] = true;
        } else {
            delete _operators[_msgSender()][operator];
        }

        emit RevokedOperator(operator, _msgSender());
    }

    /**
     * @dev See {IERC777-defaultOperators}.
     */
    function defaultOperators() public view override returns (address[] memory) {
        return _defaultOperatorsArray;
    }

    /**
     * @dev See {IERC777-operatorSend}.
     *
     * Emits {Sent} and {IERC20-Transfer} events.
     */
    function operatorSend(
        address sender,
        address recipient,
        uint256 amount,
        bytes memory data,
        bytes memory operatorData
    )
    public override
    {
        require(isOperatorFor(_msgSender(), sender), "ERC777: caller is not an operator for holder");
        _send(sender, recipient, amount, data, operatorData, true);
    }

    /**
     * @dev See {IERC777-operatorBurn}.
     *
     * Emits {Burned} and {IERC20-Transfer} events.
     */
    function operatorBurn(address account, uint256 amount, bytes memory data, bytes memory operatorData) public override {
        require(isOperatorFor(_msgSender(), account), "ERC777: caller is not an operator for holder");
        _burn(account, amount, data, operatorData);
    }

    /**
     * @dev See {IERC20-allowance}.
     *
     * Note that operator and allowance concepts are orthogonal: operators may
     * not have allowance, and accounts with allowance may not be operators
     * themselves.
     */
    function allowance(address holder, address spender) public view override returns (uint256) {
        return _allowances[holder][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Note that accounts cannot have allowance issued by their operators.
     */
    function approve(address spender, uint256 value) public override returns (bool) {
        address holder = _msgSender();
        _approve(holder, spender, value);
        return true;
    }

   /**
    * @dev See {IERC20-transferFrom}.
    *
    * Note that operator and allowance concepts are orthogonal: operators cannot
    * call `transferFrom` (unless they have allowance), and accounts with
    * allowance cannot call `operatorSend` (unless they are operators).
    *
    * Emits {Sent}, {IERC20-Transfer} and {IERC20-Approval} events.
    */
    function transferFrom(address holder, address recipient, uint256 amount) public override returns (bool) {
        require(recipient != address(0), "ERC777: transfer to the zero address");
        require(holder != address(0), "ERC777: transfer from the zero address");

        address spender = _msgSender();

        _callTokensToSend(spender, holder, recipient, amount, "", "");

        _move(spender, holder, recipient, amount, "", "");
        _approve(holder, spender, _allowances[holder][spender].sub(amount, "ERC777: transfer amount exceeds allowance"));

        _callTokensReceived(spender, holder, recipient, amount, "", "", false);

        return true;
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * If a send hook is registered for `account`, the corresponding function
     * will be called with `operator`, `data` and `operatorData`.
     *
     * See {IERC777Sender} and {IERC777Recipient}.
     *
     * Emits {Minted} and {IERC20-Transfer} events.
     *
     * Requirements
     *
     * - `account` cannot be the zero address.
     * - if `account` is a contract, it must implement the {IERC777Recipient}
     * interface.
     */
    function _mint(
        address account,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    )
    internal virtual
    {
        require(account != address(0), "ERC777: mint to the zero address");

        address operator = _msgSender();

        _beforeTokenTransfer(operator, address(0), account, amount);

        // Update state variables
        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);

        _callTokensReceived(operator, address(0), account, amount, userData, operatorData, true);

        emit Minted(operator, account, amount, userData, operatorData);
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Send tokens
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes extra information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     * @param requireReceptionAck if true, contract recipients are required to implement ERC777TokensRecipient
     */
    function _send(
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData,
        bool requireReceptionAck
    )
        internal
    {
        require(from != address(0), "ERC777: send from the zero address");
        require(to != address(0), "ERC777: send to the zero address");

        address operator = _msgSender();

        _callTokensToSend(operator, from, to, amount, userData, operatorData);

        _move(operator, from, to, amount, userData, operatorData);

        _callTokensReceived(operator, from, to, amount, userData, operatorData, requireReceptionAck);
    }

    /**
     * @dev Burn tokens
     * @param from address token holder address
     * @param amount uint256 amount of tokens to burn
     * @param data bytes extra information provided by the token holder
     * @param operatorData bytes extra information provided by the operator (if any)
     */
    function _burn(
        address from,
        uint256 amount,
        bytes memory data,
        bytes memory operatorData
    )
        internal virtual
    {
        require(from != address(0), "ERC777: burn from the zero address");

        address operator = _msgSender();

        /* Chaged by SKALE: we swapped these lines to prevent delegation of burning tokens */

        _callTokensToSend(operator, from, address(0), amount, data, operatorData);

        _beforeTokenTransfer(operator, from, address(0), amount);

        /* End of changed by SKALE */

        // Update state variables
        _balances[from] = _balances[from].sub(amount, "ERC777: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);

        emit Burned(operator, from, amount, data, operatorData);
        emit Transfer(from, address(0), amount);
    }

    function _move(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    )
        private
    {
        _beforeTokenTransfer(operator, from, to, amount);

        _balances[from] = _balances[from].sub(amount, "ERC777: transfer amount exceeds balance");
        _balances[to] = _balances[to].add(amount);

        emit Sent(operator, from, to, amount, userData, operatorData);
        emit Transfer(from, to, amount);
    }

    /**
     * @dev See {ERC20-_approve}.
     *
     * Note that accounts cannot have allowance issued by their operators.
     */
    function _approve(address holder, address spender, uint256 value) internal {
        require(holder != address(0), "ERC777: approve from the zero address");
        require(spender != address(0), "ERC777: approve to the zero address");

        _allowances[holder][spender] = value;
        emit Approval(holder, spender, value);
    }

    /**
     * @dev Call from.tokensToSend() if the interface is registered
     * @param operator address operator requesting the transfer
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes extra information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     */
    function _callTokensToSend(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    )
        /* Chaged by SKALE from private */ internal /* End of changed by SKALE */
        /* Added by SKALE */ virtual /* End of added by SKALE */
    {
        address implementer = _ERC1820_REGISTRY.getInterfaceImplementer(from, _TOKENS_SENDER_INTERFACE_HASH);
        if (implementer != address(0)) {
            IERC777Sender(implementer).tokensToSend(operator, from, to, amount, userData, operatorData);
        }
    }

    /**
     * @dev Call to.tokensReceived() if the interface is registered. Reverts if the recipient is a contract but
     * tokensReceived() was not registered for the recipient
     * @param operator address operator requesting the transfer
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes extra information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     * @param requireReceptionAck if true, contract recipients are required to implement ERC777TokensRecipient
     */
    function _callTokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData,
        bool requireReceptionAck
    )
        /* Chaged by SKALE from private */ internal /* End of changed by SKALE */
        /* Added by SKALE */ virtual /* End of added by SKALE */
    {
        address implementer = _ERC1820_REGISTRY.getInterfaceImplementer(to, _TOKENS_RECIPIENT_INTERFACE_HASH);
        if (implementer != address(0)) {
            IERC777Recipient(implementer).tokensReceived(operator, from, to, amount, userData, operatorData);
        } else if (requireReceptionAck) {
            require(!to.isContract(), "ERC777: token recipient contract has no implementer for ERC777TokensRecipient");
        }
    }

    /**
     * @dev Hook that is called before any token transfer. This includes
     * calls to {send}, {transfer}, {operatorSend}, minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, ``from``'s `tokenId` will be
     * transferred to `to`.
     * - when `from` is zero, `tokenId` will be minted for `to`.
     * - when `to` is zero, ``from``'s `tokenId` will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address operator, address from, address to, uint256 tokenId) internal virtual { }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    IDelegatableToken.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

/**
 * @dev Interface of the SkaleToken contract.
 */
interface IDelegatableToken {
    
    /**
     * @dev Returns and updates the amount of locked tokens of a given account `wallet`.
     */
    function getAndUpdateLockedAmount(address wallet) external returns (uint);
    
    /**
     * @dev Returns and updates the amount of delegated tokens of a given account `wallet`.
     */
    function getAndUpdateDelegatedAmount(address wallet) external returns (uint);
    
    /**
     * @dev Returns and updates the amount of slashed tokens of a given account `wallet`.
     */
    function getAndUpdateSlashedAmount(address wallet) external returns (uint);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "../utils/Context.sol";

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of the ERC777TokensSender standard as defined in the EIP.
 *
 * {IERC777} Token holders can be notified of operations performed on their
 * tokens by having a contract implement this interface (contract holders can be
 *  their own implementer) and registering it on the
 * https://eips.ethereum.org/EIPS/eip-1820[ERC1820 global registry].
 *
 * See {IERC1820Registry} and {ERC1820Implementer}.
 */
interface IERC777Sender {
    /**
     * @dev Called by an {IERC777} token contract whenever a registered holder's
     * (`from`) tokens are about to be moved or destroyed. The type of operation
     * is conveyed by `to` being the zero address or not.
     *
     * This call occurs _before_ the token contract's state is updated, so
     * {IERC777-balanceOf}, etc., can be used to query the pre-operation state.
     *
     * This function may revert to prevent the operation from being executed.
     */
    function tokensToSend(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external;
}

pragma solidity ^0.6.0;

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

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleTokenInternalTester.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "../SkaleToken.sol";


contract SkaleTokenInternalTester is SkaleToken {

    constructor(address contractManagerAddress, address[] memory defOps) public
    SkaleToken(contractManagerAddress, defOps)
    // solhint-disable-next-line no-empty-blocks
    { }

    function getMsgData() external view returns (bytes memory) {
        return _msgData();
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    TimeHelpersWithDebug.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../delegation/TimeHelpers.sol";


contract TimeHelpersWithDebug is TimeHelpers, OwnableUpgradeSafe {
    struct TimeShift {
        uint pointInTime;
        uint shift;
    }

    TimeShift[] private _timeShift;

    function skipTime(uint sec) external onlyOwner {
        if (_timeShift.length > 0) {
            _timeShift.push(TimeShift({pointInTime: now, shift: _timeShift[_timeShift.length.sub(1)].shift.add(sec)}));
        } else {
            _timeShift.push(TimeShift({pointInTime: now, shift: sec}));
        }
    }

    function initialize() external initializer {
        OwnableUpgradeSafe.__Ownable_init();
    }

    function timestampToMonth(uint timestamp) public view override returns (uint) {
        return super.timestampToMonth(timestamp.add(_getTimeShift(timestamp)));
    }

    function monthToTimestamp(uint month) public view override returns (uint) {
        uint shiftedTimestamp = super.monthToTimestamp(month);
        if (_timeShift.length > 0) {
            return _findTimeBeforeTimeShift(shiftedTimestamp);
        } else {
            return shiftedTimestamp;
        }
    }

    // private

    function _getTimeShift(uint timestamp) private view returns (uint) {
        if (_timeShift.length > 0) {
            if (timestamp < _timeShift[0].pointInTime) {
                return 0;
            } else if (timestamp >= _timeShift[_timeShift.length.sub(1)].pointInTime) {
                return _timeShift[_timeShift.length.sub(1)].shift;
            } else {
                uint left = 0;
                uint right = _timeShift.length.sub(1);
                while (left + 1 < right) {
                    uint middle = left.add(right).div(2);
                    if (timestamp < _timeShift[middle].pointInTime) {
                        right = middle;
                    } else {
                        left = middle;
                    }
                }
                return _timeShift[left].shift;
            }
        } else {
            return 0;
        }
    }

    function _findTimeBeforeTimeShift(uint shiftedTimestamp) private view returns (uint) {
        uint lastTimeShiftIndex = _timeShift.length.sub(1);
        if (_timeShift[lastTimeShiftIndex].pointInTime.add(_timeShift[lastTimeShiftIndex].shift)
            < shiftedTimestamp) {
            return shiftedTimestamp.sub(_timeShift[lastTimeShiftIndex].shift);
        } else {
            if (shiftedTimestamp <= _timeShift[0].pointInTime.add(_timeShift[0].shift)) {
                if (shiftedTimestamp < _timeShift[0].pointInTime) {
                    return shiftedTimestamp;
                } else {
                    return _timeShift[0].pointInTime;
                }
            } else {
                uint left = 0;
                uint right = lastTimeShiftIndex;
                while (left + 1 < right) {
                    uint middle = left.add(right).div(2);
                    if (_timeShift[middle].pointInTime.add(_timeShift[middle].shift) < shiftedTimestamp) {
                        left = middle;
                    } else {
                        right = middle;
                    }
                }
                if (shiftedTimestamp < _timeShift[right].pointInTime.add(_timeShift[left].shift)) {
                    return shiftedTimestamp.sub(_timeShift[left].shift);
                } else {
                    return _timeShift[right].pointInTime;
                }
            }
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SafeMock.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

contract SafeMock is OwnableUpgradeSafe {
    constructor() public {
        OwnableUpgradeSafe.__Ownable_init();
        multiSend(""); // this is needed to remove slither warning
    }

    function transferProxyAdminOwnership(OwnableUpgradeSafe proxyAdmin, address newOwner) external onlyOwner {
        proxyAdmin.transferOwnership(newOwner);
    }

    function destroy() external onlyOwner {
        selfdestruct(msg.sender);
    }

    /// @dev Sends multiple transactions and reverts all if one fails.
    /// @param transactions Encoded transactions. Each transaction is encoded as a packed bytes of
    ///                     operation as a uint8 with 0 for a call or 1 for a delegatecall (=> 1 byte),
    ///                     to as a address (=> 20 bytes),
    ///                     value as a uint256 (=> 32 bytes),
    ///                     data length as a uint256 (=> 32 bytes),
    ///                     data as bytes.
    ///                     see abi.encodePacked for more information on packed encoding
    function multiSend(bytes memory transactions)
        public
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let length := mload(transactions)
            let i := 0x20
            // solhint-disable-next-line no-empty-blocks
            for { } lt(i, length) { } {
                // First byte of the data is the operation.
                // We shift by 248 bits (256 - 8 [operation byte]) it right 
                // since mload will always load 32 bytes (a word).
                // This will also zero out unused data.
                let operation := shr(0xf8, mload(add(transactions, i)))
                // We offset the load address by 1 byte (operation byte)
                // We shift it right by 96 bits (256 - 160 [20 address bytes])
                // to right-align the data and zero out unused data.
                let to := shr(0x60, mload(add(transactions, add(i, 0x01))))
                // We offset the load address by 21 byte (operation byte + 20 address bytes)
                let value := mload(add(transactions, add(i, 0x15)))
                // We offset the load address by 53 byte (operation byte + 20 address bytes + 32 value bytes)
                let dataLength := mload(add(transactions, add(i, 0x35)))
                // We offset the load address by 85 byte
                // (operation byte + 20 address bytes + 32 value bytes + 32 data length bytes)
                let data := add(transactions, add(i, 0x55))
                let success := 0
                switch operation
                case 0 { success := call(gas(), to, value, data, dataLength, 0, 0) }
                case 1 { success := delegatecall(gas(), to, data, dataLength, 0, 0) }
                if eq(success, 0) { revert(0, 0) }
                // Next entry starts at 85 byte + data length
                i := add(i, add(0x55, dataLength))
            }
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDkgAlright.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../SkaleDKG.sol";
import "../ContractManager.sol";
import "../Wallets.sol";
import "../KeyStorage.sol";

/**
 * @title SkaleDkgAlright
 * @dev Contains functions to manage distributed key generation per
 * Joint-Feldman protocol.
 */
library SkaleDkgAlright {

    event AllDataReceived(bytes32 indexed schainId, uint nodeIndex);
    event SuccessfulDKG(bytes32 indexed schainId);

    function alright(
        bytes32 schainId,
        uint fromNodeIndex,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.Channel) storage channels,
        mapping(bytes32 => SkaleDKG.ProcessDKG) storage dkgProcess,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints,
        mapping(bytes32 => uint) storage lastSuccesfulDKG
        
    )
        external
    {
        SkaleDKG skaleDKG = SkaleDKG(contractManager.getContract("SkaleDKG"));
        (uint index, ) = skaleDKG.checkAndReturnIndexInGroup(schainId, fromNodeIndex, true);
        uint numberOfParticipant = channels[schainId].n;
        require(numberOfParticipant == dkgProcess[schainId].numberOfBroadcasted, "Still Broadcasting phase");
        require(
            complaints[schainId].fromNodeToComplaint != fromNodeIndex ||
            (fromNodeIndex == 0 && complaints[schainId].startComplaintBlockTimestamp == 0),
            "Node has already sent complaint"
        );
        require(!dkgProcess[schainId].completed[index], "Node is already alright");
        dkgProcess[schainId].completed[index] = true;
        dkgProcess[schainId].numberOfCompleted++;
        emit AllDataReceived(schainId, fromNodeIndex);
        if (dkgProcess[schainId].numberOfCompleted == numberOfParticipant) {
            lastSuccesfulDKG[schainId] = now;
            channels[schainId].active = false;
            KeyStorage(contractManager.getContract("KeyStorage")).finalizePublicKey(schainId);
            emit SuccessfulDKG(schainId);
        }
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDKG.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;
import "./Permissions.sol";
import "./delegation/Punisher.sol";
import "./SlashingTable.sol";
import "./Schains.sol";
import "./SchainsInternal.sol";
import "./utils/FieldOperations.sol";
import "./NodeRotation.sol";
import "./KeyStorage.sol";
import "./interfaces/ISkaleDKG.sol";
import "./thirdparty/ECDH.sol";
import "./utils/Precompiled.sol";
import "./Wallets.sol";
import "./dkg/SkaleDkgAlright.sol";
import "./dkg/SkaleDkgBroadcast.sol";
import "./dkg/SkaleDkgComplaint.sol";
import "./dkg/SkaleDkgPreResponse.sol";
import "./dkg/SkaleDkgResponse.sol";

/**
 * @title SkaleDKG
 * @dev Contains functions to manage distributed key generation per
 * Joint-Feldman protocol.
 */
contract SkaleDKG is Permissions, ISkaleDKG {
    using Fp2Operations for Fp2Operations.Fp2Point;
    using G2Operations for G2Operations.G2Point;

    enum DkgFunction {Broadcast, Alright, ComplaintBadData, PreResponse, Complaint, Response}

    struct Channel {
        bool active;
        uint n;
        uint startedBlockTimestamp;
        uint startedBlock;
    }

    struct ProcessDKG {
        uint numberOfBroadcasted;
        uint numberOfCompleted;
        bool[] broadcasted;
        bool[] completed;
    }

    struct ComplaintData {
        uint nodeToComplaint;
        uint fromNodeToComplaint;
        uint startComplaintBlockTimestamp;
        bool isResponse;
        bytes32 keyShare;
        G2Operations.G2Point sumOfVerVec;
    }

    struct KeyShare {
        bytes32[2] publicKey;
        bytes32 share;
    }

    struct Context {
        bool isDebt;
        uint delta;
        DkgFunction dkgFunction;
    }

    uint public constant COMPLAINT_TIMELIMIT = 1800;

    mapping(bytes32 => Channel) public channels;

    mapping(bytes32 => uint) public lastSuccesfulDKG;

    mapping(bytes32 => ProcessDKG) public dkgProcess;

    mapping(bytes32 => ComplaintData) public complaints;

    mapping(bytes32 => uint) public startAlrightTimestamp;

    mapping(bytes32 => mapping(uint => bytes32)) public hashedData;
    
    mapping(bytes32 => uint) private _badNodes;
    
    /**
     * @dev Emitted when a channel is opened.
     */
    event ChannelOpened(bytes32 schainId);

    /**
     * @dev Emitted when a channel is closed.
     */
    event ChannelClosed(bytes32 schainId);

    /**
     * @dev Emitted when a node broadcasts keyshare.
     */
    event BroadcastAndKeyShare(
        bytes32 indexed schainId,
        uint indexed fromNode,
        G2Operations.G2Point[] verificationVector,
        KeyShare[] secretKeyContribution
    );

    /**
     * @dev Emitted when all group data is received by node.
     */
    event AllDataReceived(bytes32 indexed schainId, uint nodeIndex);

    /**
     * @dev Emitted when DKG is successful.
     */
    event SuccessfulDKG(bytes32 indexed schainId);

    /**
     * @dev Emitted when a complaint against a node is verified.
     */
    event BadGuy(uint nodeIndex);

    /**
     * @dev Emitted when DKG failed.
     */
    event FailedDKG(bytes32 indexed schainId);

    /**
     * @dev Emitted when a new node is rotated in.
     */
    event NewGuy(uint nodeIndex);

    /**
     * @dev Emitted when an incorrect complaint is sent.
     */
    event ComplaintError(string error);

    /**
     * @dev Emitted when a complaint is sent.
     */
    event ComplaintSent(
        bytes32 indexed schainId, uint indexed fromNodeIndex, uint indexed toNodeIndex);

    modifier correctGroup(bytes32 schainId) {
        require(channels[schainId].active, "Group is not created");
        _;
    }

    modifier correctGroupWithoutRevert(bytes32 schainId) {
        if (!channels[schainId].active) {
            emit ComplaintError("Group is not created");
        } else {
            _;
        }
    }

    modifier correctNode(bytes32 schainId, uint nodeIndex) {
        (uint index, ) = checkAndReturnIndexInGroup(schainId, nodeIndex, true);
        _;
    }

    modifier correctNodeWithoutRevert(bytes32 schainId, uint nodeIndex) {
        (, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        if (!check) {
            emit ComplaintError("Node is not in this group");
        } else {
            _;
        }
    }

    modifier onlyNodeOwner(uint nodeIndex) {
        _checkMsgSenderIsNodeOwner(nodeIndex);
        _;
    }
    
    modifier refundGasBySchain(bytes32 schainId, Context memory context) {
        uint gasTotal = gasleft();
        _;
        _refundGasBySchain(schainId, gasTotal, context);
    }

    modifier refundGasByValidatorToSchain(bytes32 schainId, Context memory context) {
        uint gasTotal = gasleft();
        _;
        _refundGasBySchain(schainId, gasTotal, context);
        _refundGasByValidatorToSchain(schainId);
    }

    function alright(bytes32 schainId, uint fromNodeIndex)
        external
        refundGasBySchain(schainId, 
            Context({
                isDebt: false,
                delta: ConstantsHolder(contractManager.getConstantsHolder()).ALRIGHT_DELTA(), 
                dkgFunction: DkgFunction.Alright
        }))
        correctGroup(schainId)
        onlyNodeOwner(fromNodeIndex)
    {
        SkaleDkgAlright.alright(
            schainId,
            fromNodeIndex,
            contractManager,
            channels,
            dkgProcess,
            complaints,
            lastSuccesfulDKG
        );
    }

    function broadcast(
        bytes32 schainId,
        uint nodeIndex,
        G2Operations.G2Point[] memory verificationVector,
        KeyShare[] memory secretKeyContribution
    )
        external
        refundGasBySchain(schainId,
            Context({
                isDebt: false,
                delta: ConstantsHolder(contractManager.getConstantsHolder()).BROADCAST_DELTA(),
                dkgFunction: DkgFunction.Broadcast
        }))
        correctGroup(schainId)
        onlyNodeOwner(nodeIndex)
    {
        SkaleDkgBroadcast.broadcast(
            schainId,
            nodeIndex,
            verificationVector,
            secretKeyContribution,
            contractManager,
            channels,
            dkgProcess,
            hashedData
        );
    }


    function complaintBadData(bytes32 schainId, uint fromNodeIndex, uint toNodeIndex)
        external
        refundGasBySchain(
            schainId,
            Context({
                isDebt: true,
                delta: ConstantsHolder(contractManager.getConstantsHolder()).COMPLAINT_BAD_DATA_DELTA(),
                dkgFunction: DkgFunction.ComplaintBadData
        }))
        correctGroupWithoutRevert(schainId)
        correctNode(schainId, fromNodeIndex)
        correctNodeWithoutRevert(schainId, toNodeIndex)
        onlyNodeOwner(fromNodeIndex)
    { 
        SkaleDkgComplaint.complaintBadData(
            schainId,
            fromNodeIndex,
            toNodeIndex,
            contractManager,
            complaints
        );
    }

    function preResponse(
        bytes32 schainId,
        uint fromNodeIndex,
        G2Operations.G2Point[] memory verificationVector,
        G2Operations.G2Point[] memory verificationVectorMult,
        KeyShare[] memory secretKeyContribution
    )
        external
        refundGasBySchain(
            schainId,
            Context({
                isDebt: true,
                delta: ConstantsHolder(contractManager.getConstantsHolder()).PRE_RESPONSE_DELTA(),
                dkgFunction: DkgFunction.PreResponse
        }))
        correctGroup(schainId)
        onlyNodeOwner(fromNodeIndex)
    {
        SkaleDkgPreResponse.preResponse(
            schainId,
            fromNodeIndex,
            verificationVector,
            verificationVectorMult,
            secretKeyContribution,
            contractManager,
            complaints,
            hashedData
        );
    }

    function complaint(bytes32 schainId, uint fromNodeIndex, uint toNodeIndex)
        external
        refundGasByValidatorToSchain(
            schainId,
            Context({
                isDebt: true,
                delta: ConstantsHolder(contractManager.getConstantsHolder()).COMPLAINT_DELTA(),
                dkgFunction: DkgFunction.Complaint
        }))
        correctGroupWithoutRevert(schainId)
        correctNode(schainId, fromNodeIndex)
        correctNodeWithoutRevert(schainId, toNodeIndex)
        onlyNodeOwner(fromNodeIndex)
    {
        SkaleDkgComplaint.complaint(
            schainId,
            fromNodeIndex,
            toNodeIndex,
            contractManager,
            channels,
            complaints,
            startAlrightTimestamp
        );
    }

    function response(
        bytes32 schainId,
        uint fromNodeIndex,
        uint secretNumber,
        G2Operations.G2Point memory multipliedShare
    )
        external
        refundGasByValidatorToSchain(
            schainId,
            Context({isDebt: true,
                delta: ConstantsHolder(contractManager.getConstantsHolder()).RESPONSE_DELTA(),
                dkgFunction: DkgFunction.Response
        }))
        correctGroup(schainId)
        onlyNodeOwner(fromNodeIndex)
    {
        SkaleDkgResponse.response(
            schainId,
            fromNodeIndex,
            secretNumber,
            multipliedShare,
            contractManager,
            channels,
            complaints
        );
    }

    /**
     * @dev Allows Schains and NodeRotation contracts to open a channel.
     * 
     * Emits a {ChannelOpened} event.
     * 
     * Requirements:
     * 
     * - Channel is not already created.
     */
    function openChannel(bytes32 schainId) external override allowTwo("Schains","NodeRotation") {
        _openChannel(schainId);
    }

    /**
     * @dev Allows SchainsInternal contract to delete a channel.
     *
     * Requirements:
     *
     * - Channel must exist.
     */
    function deleteChannel(bytes32 schainId) external override allow("SchainsInternal") {
        delete channels[schainId];
        delete dkgProcess[schainId];
        delete complaints[schainId];
        KeyStorage(contractManager.getContract("KeyStorage")).deleteKey(schainId);
    }

    function setStartAlrightTimestamp(bytes32 schainId) external allow("SkaleDKG") {
        startAlrightTimestamp[schainId] = now;
    }

    function setBadNode(bytes32 schainId, uint nodeIndex) external allow("SkaleDKG") {
        _badNodes[schainId] = nodeIndex;
    }

    function finalizeSlashing(bytes32 schainId, uint badNode) external allow("SkaleDKG") {
        NodeRotation nodeRotation = NodeRotation(contractManager.getContract("NodeRotation"));
        SchainsInternal schainsInternal = SchainsInternal(
            contractManager.getContract("SchainsInternal")
        );
        emit BadGuy(badNode);
        emit FailedDKG(schainId);

        schainsInternal.makeSchainNodesInvisible(schainId);
        if (schainsInternal.isAnyFreeNode(schainId)) {
            uint newNode = nodeRotation.rotateNode(
                badNode,
                schainId,
                false,
                true
            );
            emit NewGuy(newNode);
        } else {
            _openChannel(schainId);
            schainsInternal.removeNodeFromSchain(
                badNode,
                schainId
            );
            channels[schainId].active = false;
        }
        schainsInternal.makeSchainNodesVisible(schainId);
        Punisher(contractManager.getPunisher()).slash(
            Nodes(contractManager.getContract("Nodes")).getValidatorId(badNode),
            SlashingTable(contractManager.getContract("SlashingTable")).getPenalty("FailedDKG")
        );
    }

    function getChannelStartedTime(bytes32 schainId) external view returns (uint) {
        return channels[schainId].startedBlockTimestamp;
    }

    function getChannelStartedBlock(bytes32 schainId) external view returns (uint) {
        return channels[schainId].startedBlock;
    }

    function getNumberOfBroadcasted(bytes32 schainId) external view returns (uint) {
        return dkgProcess[schainId].numberOfBroadcasted;
    }

    function getNumberOfCompleted(bytes32 schainId) external view returns (uint) {
        return dkgProcess[schainId].numberOfCompleted;
    }

    function getTimeOfLastSuccessfulDKG(bytes32 schainId) external view returns (uint) {
        return lastSuccesfulDKG[schainId];
    }

    function getComplaintData(bytes32 schainId) external view returns (uint, uint) {
        return (complaints[schainId].fromNodeToComplaint, complaints[schainId].nodeToComplaint);
    }

    function getComplaintStartedTime(bytes32 schainId) external view returns (uint) {
        return complaints[schainId].startComplaintBlockTimestamp;
    }

    function getAlrightStartedTime(bytes32 schainId) external view returns (uint) {
        return startAlrightTimestamp[schainId];
    }

    /**
     * @dev Checks whether channel is opened.
     */
    function isChannelOpened(bytes32 schainId) external override view returns (bool) {
        return channels[schainId].active;
    }

    function isLastDKGSuccessful(bytes32 schainId) external override view returns (bool) {
        return channels[schainId].startedBlockTimestamp <= lastSuccesfulDKG[schainId];
    }

    /**
     * @dev Checks whether broadcast is possible.
     */
    function isBroadcastPossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            !dkgProcess[schainId].broadcasted[index];
    }

    /**
     * @dev Checks whether complaint is possible.
     */
    function isComplaintPossible(
        bytes32 schainId,
        uint fromNodeIndex,
        uint toNodeIndex
    )
        external
        view
        returns (bool)
    {
        (uint indexFrom, bool checkFrom) = checkAndReturnIndexInGroup(schainId, fromNodeIndex, false);
        (uint indexTo, bool checkTo) = checkAndReturnIndexInGroup(schainId, toNodeIndex, false);
        if (!checkFrom || !checkTo)
            return false;
        bool complaintSending = (
                complaints[schainId].nodeToComplaint == uint(-1) &&
                dkgProcess[schainId].broadcasted[indexTo] &&
                !dkgProcess[schainId].completed[indexFrom]
            ) ||
            (
                dkgProcess[schainId].broadcasted[indexTo] &&
                complaints[schainId].startComplaintBlockTimestamp.add(_getComplaintTimelimit()) <= block.timestamp &&
                complaints[schainId].nodeToComplaint == toNodeIndex
            ) ||
            (
                !dkgProcess[schainId].broadcasted[indexTo] &&
                complaints[schainId].nodeToComplaint == uint(-1) &&
                channels[schainId].startedBlockTimestamp.add(_getComplaintTimelimit()) <= block.timestamp
            ) ||
            (
                complaints[schainId].nodeToComplaint == uint(-1) &&
                isEveryoneBroadcasted(schainId) &&
                dkgProcess[schainId].completed[indexFrom] &&
                !dkgProcess[schainId].completed[indexTo] &&
                startAlrightTimestamp[schainId].add(_getComplaintTimelimit()) <= block.timestamp
            );
        return channels[schainId].active &&
            dkgProcess[schainId].broadcasted[indexFrom] &&
            _isNodeOwnedByMessageSender(fromNodeIndex, msg.sender) &&
            complaintSending;
    }

    /**
     * @dev Checks whether sending Alright response is possible.
     */
    function isAlrightPossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            channels[schainId].n == dkgProcess[schainId].numberOfBroadcasted &&
            (complaints[schainId].fromNodeToComplaint != nodeIndex ||
            (nodeIndex == 0 && complaints[schainId].startComplaintBlockTimestamp == 0)) &&
            !dkgProcess[schainId].completed[index];
    }

    /**
     * @dev Checks whether sending a pre-response is possible.
     */
    function isPreResponsePossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            complaints[schainId].nodeToComplaint == nodeIndex &&
            !complaints[schainId].isResponse;
    }

    /**
     * @dev Checks whether sending a response is possible.
     */
    function isResponsePossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            complaints[schainId].nodeToComplaint == nodeIndex &&
            complaints[schainId].isResponse;
    }

    function isNodeBroadcasted(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return check && dkgProcess[schainId].broadcasted[index];
    }

     /**
     * @dev Checks whether all data has been received by node.
     */
    function isAllDataReceived(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return check && dkgProcess[schainId].completed[index];
    }

    function hashData(
        KeyShare[] memory secretKeyContribution,
        G2Operations.G2Point[] memory verificationVector
    )
        external
        pure
        returns (bytes32)
    {
        bytes memory data;
        for (uint i = 0; i < secretKeyContribution.length; i++) {
            data = abi.encodePacked(data, secretKeyContribution[i].publicKey, secretKeyContribution[i].share);
        }
        for (uint i = 0; i < verificationVector.length; i++) {
            data = abi.encodePacked(
                data,
                verificationVector[i].x.a,
                verificationVector[i].x.b,
                verificationVector[i].y.a,
                verificationVector[i].y.b
            );
        }
        return keccak256(data);
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
    }

    function checkAndReturnIndexInGroup(
        bytes32 schainId,
        uint nodeIndex,
        bool revertCheck
    )
        public
        view
        returns (uint, bool)
    {
        uint index = SchainsInternal(contractManager.getContract("SchainsInternal"))
            .getNodeIndexInGroup(schainId, nodeIndex);
        if (index >= channels[schainId].n && revertCheck) {
            revert("Node is not in this group");
        }
        return (index, index < channels[schainId].n);
    }

    function _refundGasBySchain(bytes32 schainId, uint gasTotal, Context memory context) private {
        Wallets wallets = Wallets(payable(contractManager.getContract("Wallets")));
        bool isLastNode = channels[schainId].n == dkgProcess[schainId].numberOfCompleted;
        if (context.dkgFunction == DkgFunction.Alright && isLastNode) {
            wallets.refundGasBySchain(
                schainId, msg.sender, gasTotal.sub(gasleft()).add(context.delta).sub(74800), context.isDebt
            );
        } else if (context.dkgFunction == DkgFunction.Complaint && gasTotal.sub(gasleft()) > 2e6) {
            wallets.refundGasBySchain(
                schainId, msg.sender, gasTotal.sub(gasleft()).add(context.delta).sub(640000), context.isDebt
            );
        } else if (context.dkgFunction == DkgFunction.Complaint && gasTotal.sub(gasleft()) > 1e6) {
            wallets.refundGasBySchain(
                schainId, msg.sender, gasTotal.sub(gasleft()).add(context.delta).sub(270000), context.isDebt
            );
        } else if (context.dkgFunction == DkgFunction.Response){
            wallets.refundGasBySchain(
                schainId, msg.sender, gasTotal.sub(gasleft()).sub(context.delta), context.isDebt
            );
        } else {
            wallets.refundGasBySchain(
                schainId, msg.sender, gasTotal.sub(gasleft()).add(context.delta), context.isDebt
            );
        }
    }

    function _refundGasByValidatorToSchain(bytes32 schainId) private {
        uint validatorId = Nodes(contractManager.getContract("Nodes"))
         .getValidatorId(_badNodes[schainId]);
         Wallets(payable(contractManager.getContract("Wallets")))
         .refundGasByValidatorToSchain(validatorId, schainId);
        delete _badNodes[schainId];
    }

    function _openChannel(bytes32 schainId) private {
        SchainsInternal schainsInternal = SchainsInternal(
            contractManager.getContract("SchainsInternal")
        );

        uint len = schainsInternal.getNumberOfNodesInGroup(schainId);
        channels[schainId].active = true;
        channels[schainId].n = len;
        delete dkgProcess[schainId].completed;
        delete dkgProcess[schainId].broadcasted;
        dkgProcess[schainId].broadcasted = new bool[](len);
        dkgProcess[schainId].completed = new bool[](len);
        complaints[schainId].fromNodeToComplaint = uint(-1);
        complaints[schainId].nodeToComplaint = uint(-1);
        delete complaints[schainId].startComplaintBlockTimestamp;
        delete dkgProcess[schainId].numberOfBroadcasted;
        delete dkgProcess[schainId].numberOfCompleted;
        channels[schainId].startedBlockTimestamp = now;
        channels[schainId].startedBlock = block.number;
        KeyStorage(contractManager.getContract("KeyStorage")).initPublicKeyInProgress(schainId);

        emit ChannelOpened(schainId);
    }

    function isEveryoneBroadcasted(bytes32 schainId) public view returns (bool) {
        return channels[schainId].n == dkgProcess[schainId].numberOfBroadcasted;
    }

    function _isNodeOwnedByMessageSender(uint nodeIndex, address from) private view returns (bool) {
        return Nodes(contractManager.getContract("Nodes")).isNodeExist(from, nodeIndex);
    }

    function _checkMsgSenderIsNodeOwner(uint nodeIndex) private view {
        require(_isNodeOwnedByMessageSender(nodeIndex, msg.sender), "Node does not exist for message sender");
    }

    function _getComplaintTimelimit() private view returns (uint) {
        return ConstantsHolder(contractManager.getConstantsHolder()).complaintTimelimit();
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Wallets.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "./Permissions.sol";
import "./delegation/ValidatorService.sol";
import "./SchainsInternal.sol";
import "./Nodes.sol";

/**
 * @title Wallets
 * @dev Contract contains logic to perform automatic self-recharging ether for nodes
 */
contract Wallets is Permissions {

    mapping (uint => uint) private _validatorWallets;
    mapping (bytes32 => uint) private _schainWallets;
    mapping (bytes32 => uint) private _schainDebts;

    /**
     * @dev Emitted when the validator wallet was funded
     */
    event ValidatorWalletRecharged(address sponsor, uint amount, uint validatorId);

    /**
     * @dev Emitted when the schain wallet was funded
     */
    event SchainWalletRecharged(address sponsor, uint amount, bytes32 schainId);

    /**
     * @dev Emitted when the node received a refund from validator to its wallet
     */
    event NodeRefundedByValidator(address node, uint validatorId, uint amount);

    /**
     * @dev Emitted when the node received a refund from schain to its wallet
     */
    event NodeRefundedBySchain(address node, bytes32 schainId, uint amount);

    /**
     * @dev Is executed on a call to the contract with empty calldata. 
     * This is the function that is executed on plain Ether transfers,
     * so validator or schain owner can use usual transfer ether to recharge wallet.
     */
    receive() external payable {
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        bytes32[] memory schainIds = schainsInternal.getSchainIdsByAddress(msg.sender);
        if (schainIds.length == 1) {
            rechargeSchainWallet(schainIds[0]);
        } else {
            uint validatorId = validatorService.getValidatorId(msg.sender);
            rechargeValidatorWallet(validatorId);
        }
    }

    /**
     * @dev Reimburse gas for node by validator wallet. If validator wallet has not enough funds 
     * the node will receive the entire remaining amount in the validator's wallet.
     * `validatorId` - validator that will reimburse desired transaction
     * `spender` - address to send reimbursed funds
     * `spentGas` - amount of spent gas that should be reimbursed to desired node
     * 
     * Emits a {NodeRefundedByValidator} event.
     * 
     * Requirements: 
     * - Given validator should exist
     */
    function refundGasByValidator(
        uint validatorId,
        address payable spender,
        uint spentGas
    )
        external
        allowTwo("SkaleManager", "SkaleDKG")
    {
        require(validatorId != 0, "ValidatorId could not be zero");
        uint amount = tx.gasprice * spentGas;
        if (amount <= _validatorWallets[validatorId]) {
            _validatorWallets[validatorId] = _validatorWallets[validatorId].sub(amount);
            emit NodeRefundedByValidator(spender, validatorId, amount);
            spender.transfer(amount);
        } else {
            uint wholeAmount = _validatorWallets[validatorId];
            // solhint-disable-next-line reentrancy
            delete _validatorWallets[validatorId];
            emit NodeRefundedByValidator(spender, validatorId, wholeAmount);
            spender.transfer(wholeAmount);
        }
    }

    /**
     * @dev Returns the amount owed to the owner of the chain by the validator, 
     * if the validator does not have enough funds, then everything 
     * that the validator has will be returned to the owner of the chain.
     */
    function refundGasByValidatorToSchain(uint validatorId, bytes32 schainId) external allow("SkaleDKG") {
        uint debtAmount = _schainDebts[schainId];
        uint validatorWallet = _validatorWallets[validatorId];
        if (debtAmount <= validatorWallet) {
            _validatorWallets[validatorId] = validatorWallet.sub(debtAmount);
        } else {
            debtAmount = validatorWallet;
            delete _validatorWallets[validatorId];
        }
        _schainWallets[schainId] = _schainWallets[schainId].add(debtAmount);
        delete _schainDebts[schainId];
    }

    /**
     * @dev Reimburse gas for node by schain wallet. If schain wallet has not enough funds 
     * than transaction will be reverted.
     * `schainId` - schain that will reimburse desired transaction
     * `spender` - address to send reimbursed funds
     * `spentGas` - amount of spent gas that should be reimbursed to desired node
     * `isDebt` - parameter that indicates whether this amount should be recorded as debt for the validator
     * 
     * Emits a {NodeRefundedBySchain} event.
     * 
     * Requirements: 
     * - Given schain should exist
     * - Schain wallet should have enough funds
     */
    function refundGasBySchain(
        bytes32 schainId,
        address payable spender,
        uint spentGas,
        bool isDebt
    )
        external
        allowTwo("SkaleDKG", "MessageProxyForMainnet")
    {
        uint amount = tx.gasprice * spentGas;
        if (isDebt) {
            amount += (_schainDebts[schainId] == 0 ? 21000 : 6000) * tx.gasprice;
            _schainDebts[schainId] = _schainDebts[schainId].add(amount);
        }
        require(schainId != bytes32(0), "SchainId cannot be null");
        require(amount <= _schainWallets[schainId], "Schain wallet has not enough funds");
        _schainWallets[schainId] = _schainWallets[schainId].sub(amount);
        emit NodeRefundedBySchain(spender, schainId, amount);
        spender.transfer(amount);
    }

    /**
     * @dev Withdraws money from schain wallet. Possible to execute only after deleting schain.
     * `schainOwner` - address of schain owner that will receive rest of the schain balance
     * `schainId` - schain wallet from which money is withdrawn
     * 
     * Requirements: 
     * - Executable only after initing delete schain
     */
    function withdrawFundsFromSchainWallet(address payable schainOwner, bytes32 schainId) external allow("Schains") {
        uint amount = _schainWallets[schainId];
        delete _schainWallets[schainId];
        schainOwner.transfer(amount);
    }
    
    /**
     * @dev Withdraws money from vaildator wallet.
     * `amount` - the amount of money in wei
     * 
     * Requirements: 
     * - Validator must have sufficient withdrawal amount
     */
    function withdrawFundsFromValidatorWallet(uint amount) external {
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        uint validatorId = validatorService.getValidatorId(msg.sender);
        require(amount <= _validatorWallets[validatorId], "Balance is too low");
        _validatorWallets[validatorId] = _validatorWallets[validatorId].sub(amount);
        msg.sender.transfer(amount);
    }

    function getSchainBalance(bytes32 schainId) external view returns (uint) {
        return _schainWallets[schainId];
    }

    function getValidatorBalance(uint validatorId) external view returns (uint) {
        return _validatorWallets[validatorId];
    }

    /**
     * @dev Recharge the validator wallet by id.
     * `validatorId` - id of existing validator.
     * 
     * Emits a {ValidatorWalletRecharged} event.
     * 
     * Requirements: 
     * - Given validator must exist
     */
    function rechargeValidatorWallet(uint validatorId) public payable {
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        require(validatorService.validatorExists(validatorId), "Validator does not exists");
        _validatorWallets[validatorId] = _validatorWallets[validatorId].add(msg.value);
        emit ValidatorWalletRecharged(msg.sender, msg.value, validatorId);
    }

    /**
     * @dev Recharge the schain wallet by schainId (hash of schain name).
     * `schainId` - id of existing schain.
     * 
     * Emits a {SchainWalletRecharged} event.
     * 
     * Requirements: 
     * - Given schain must be created
     */
    function rechargeSchainWallet(bytes32 schainId) public payable {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        require(schainsInternal.isSchainActive(schainId), "Schain should be active for recharging");
        _schainWallets[schainId] = _schainWallets[schainId].add(msg.value);
        emit SchainWalletRecharged(msg.sender, msg.value, schainId);
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    KeyStorage.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;
import "./Decryption.sol";
import "./Permissions.sol";
import "./SchainsInternal.sol";
import "./thirdparty/ECDH.sol";
import "./utils/Precompiled.sol";
import "./utils/FieldOperations.sol";

contract KeyStorage is Permissions {
    using Fp2Operations for Fp2Operations.Fp2Point;
    using G2Operations for G2Operations.G2Point;

    struct BroadcastedData {
        KeyShare[] secretKeyContribution;
        G2Operations.G2Point[] verificationVector;
    }

    struct KeyShare {
        bytes32[2] publicKey;
        bytes32 share;
    }

    // Unused variable!!
    mapping(bytes32 => mapping(uint => BroadcastedData)) private _data;
    // 
    
    mapping(bytes32 => G2Operations.G2Point) private _publicKeysInProgress;
    mapping(bytes32 => G2Operations.G2Point) private _schainsPublicKeys;

    // Unused variable
    mapping(bytes32 => G2Operations.G2Point[]) private _schainsNodesPublicKeys;
    //

    mapping(bytes32 => G2Operations.G2Point[]) private _previousSchainsPublicKeys;

    function deleteKey(bytes32 schainId) external allow("SkaleDKG") {
        _previousSchainsPublicKeys[schainId].push(_schainsPublicKeys[schainId]);
        delete _schainsPublicKeys[schainId];
        delete _data[schainId][0];
        delete _schainsNodesPublicKeys[schainId];
    }

    function initPublicKeyInProgress(bytes32 schainId) external allow("SkaleDKG") {
        _publicKeysInProgress[schainId] = G2Operations.getG2Zero();
    }

    function adding(bytes32 schainId, G2Operations.G2Point memory value) external allow("SkaleDKG") {
        require(value.isG2(), "Incorrect g2 point");
        _publicKeysInProgress[schainId] = value.addG2(_publicKeysInProgress[schainId]);
    }

    function finalizePublicKey(bytes32 schainId) external allow("SkaleDKG") {
        if (!_isSchainsPublicKeyZero(schainId)) {
            _previousSchainsPublicKeys[schainId].push(_schainsPublicKeys[schainId]);
        }
        _schainsPublicKeys[schainId] = _publicKeysInProgress[schainId];
        delete _publicKeysInProgress[schainId];
    }

    function getCommonPublicKey(bytes32 schainId) external view returns (G2Operations.G2Point memory) {
        return _schainsPublicKeys[schainId];
    }

    function getPreviousPublicKey(bytes32 schainId) external view returns (G2Operations.G2Point memory) {
        uint length = _previousSchainsPublicKeys[schainId].length;
        if (length == 0) {
            return G2Operations.getG2Zero();
        }
        return _previousSchainsPublicKeys[schainId][length - 1];
    }

    function getAllPreviousPublicKeys(bytes32 schainId) external view returns (G2Operations.G2Point[] memory) {
        return _previousSchainsPublicKeys[schainId];
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
    }

    function _isSchainsPublicKeyZero(bytes32 schainId) private view returns (bool) {
        return _schainsPublicKeys[schainId].x.a == 0 &&
            _schainsPublicKeys[schainId].x.b == 0 &&
            _schainsPublicKeys[schainId].y.a == 0 &&
            _schainsPublicKeys[schainId].y.b == 0;
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SlashingTable.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "./Permissions.sol";

/**
 * @title Slashing Table
 * @dev This contract manages slashing conditions and penalties.
 */
contract SlashingTable is Permissions {
    mapping (uint => uint) private _penalties;

    /**
     * @dev Allows the Owner to set a slashing penalty in SKL tokens for a
     * given offense.
     */
    function setPenalty(string calldata offense, uint penalty) external onlyOwner {
        _penalties[uint(keccak256(abi.encodePacked(offense)))] = penalty;
    }

    /**
     * @dev Returns the penalty in SKL tokens for a given offense.
     */
    function getPenalty(string calldata offense) external view returns (uint) {
        uint penalty = _penalties[uint(keccak256(abi.encodePacked(offense)))];
        return penalty;
    }

    function initialize(address contractManagerAddress) public override initializer {
        Permissions.initialize(contractManagerAddress);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Schains.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "./Permissions.sol";
import "./SchainsInternal.sol";
import "./ConstantsHolder.sol";
import "./KeyStorage.sol";
import "./SkaleVerifier.sol";
import "./utils/FieldOperations.sol";
import "./NodeRotation.sol";
import "./interfaces/ISkaleDKG.sol";
import "./Wallets.sol";


/**
 * @title Schains
 * @dev Contains functions to manage Schains such as Schain creation,
 * deletion, and rotation.
 */
contract Schains is Permissions {

    struct SchainParameters {
        uint lifetime;
        uint8 typeOfSchain;
        uint16 nonce;
        string name;
    }

    bytes32 public constant SCHAIN_CREATOR_ROLE = keccak256("SCHAIN_CREATOR_ROLE");

    /**
     * @dev Emitted when an schain is created.
     */
    event SchainCreated(
        string name,
        address owner,
        uint partOfNode,
        uint lifetime,
        uint numberOfNodes,
        uint deposit,
        uint16 nonce,
        bytes32 schainId,
        uint time,
        uint gasSpend
    );

    /**
     * @dev Emitted when an schain is deleted.
     */
    event SchainDeleted(
        address owner,
        string name,
        bytes32 indexed schainId
    );

    /**
     * @dev Emitted when a node in an schain is rotated.
     */
    event NodeRotated(
        bytes32 schainId,
        uint oldNode,
        uint newNode
    );

    /**
     * @dev Emitted when a node is added to an schain.
     */
    event NodeAdded(
        bytes32 schainId,
        uint newNode
    );

    /**
     * @dev Emitted when a group of nodes is created for an schain.
     */
    event SchainNodes(
        string name,
        bytes32 schainId,
        uint[] nodesInGroup,
        uint time,
        uint gasSpend
    );

    /**
     * @dev Allows SkaleManager contract to create an Schain.
     * 
     * Emits an {SchainCreated} event.
     * 
     * Requirements:
     * 
     * - Schain type is valid.
     * - There is sufficient deposit to create type of schain.
     */
    function addSchain(address from, uint deposit, bytes calldata data) external allow("SkaleManager") {
        SchainParameters memory schainParameters = _fallbackSchainParametersDataConverter(data);
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getConstantsHolder());
        uint schainCreationTimeStamp = constantsHolder.schainCreationTimeStamp();
        uint minSchainLifetime = constantsHolder.minimalSchainLifetime();
        require(now >= schainCreationTimeStamp, "It is not a time for creating Schain");
        require(
            schainParameters.lifetime >= minSchainLifetime,
            "Minimal schain lifetime should be satisfied"
        );
        require(
            getSchainPrice(schainParameters.typeOfSchain, schainParameters.lifetime) <= deposit,
            "Not enough money to create Schain");

        _addSchain(from, deposit, schainParameters);
    }

    /**
     * @dev Allows the foundation to create an Schain without tokens.
     * 
     * Emits an {SchainCreated} event.
     * 
     * Requirements:
     * 
     * - sender is granted with SCHAIN_CREATOR_ROLE
     * - Schain type is valid.
     */
    function addSchainByFoundation(
        uint lifetime,
        uint8 typeOfSchain,
        uint16 nonce,
        string calldata name,
        address schainOwner
    )
        external
        payable
    {
        require(hasRole(SCHAIN_CREATOR_ROLE, msg.sender), "Sender is not authorized to create schain");

        SchainParameters memory schainParameters = SchainParameters({
            lifetime: lifetime,
            typeOfSchain: typeOfSchain,
            nonce: nonce,
            name: name
        });

        address _schainOwner;
        if (schainOwner != address(0)) {
            _schainOwner = schainOwner;
        } else {
            _schainOwner = msg.sender;
        }

        _addSchain(_schainOwner, 0, schainParameters);
        bytes32 schainId = keccak256(abi.encodePacked(name));
        Wallets(payable(contractManager.getContract("Wallets"))).rechargeSchainWallet{value: msg.value}(schainId);
    }

    /**
     * @dev Allows SkaleManager to remove an schain from the network.
     * Upon removal, the space availability of each node is updated.
     * 
     * Emits an {SchainDeleted} event.
     * 
     * Requirements:
     * 
     * - Executed by schain owner.
     */
    function deleteSchain(address from, string calldata name) external allow("SkaleManager") {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        bytes32 schainId = keccak256(abi.encodePacked(name));
        require(
            schainsInternal.isOwnerAddress(from, schainId),
            "Message sender is not the owner of the Schain"
        );

        _deleteSchain(name, schainsInternal);
    }

    /**
     * @dev Allows SkaleManager to delete any Schain.
     * Upon removal, the space availability of each node is updated.
     * 
     * Emits an {SchainDeleted} event.
     * 
     * Requirements:
     * 
     * - Schain exists.
     */
    function deleteSchainByRoot(string calldata name) external allow("SkaleManager") {
        _deleteSchain(name, SchainsInternal(contractManager.getContract("SchainsInternal")));
    }

    /**
     * @dev Allows SkaleManager contract to restart schain creation by forming a
     * new schain group. Executed when DKG procedure fails and becomes stuck.
     * 
     * Emits a {NodeAdded} event.
     * 
     * Requirements:
     * 
     * - Previous DKG procedure must have failed.
     * - DKG failure got stuck because there were no free nodes to rotate in.
     * - A free node must be released in the network.
     */
    function restartSchainCreation(string calldata name) external allow("SkaleManager") {
        NodeRotation nodeRotation = NodeRotation(contractManager.getContract("NodeRotation"));
        bytes32 schainId = keccak256(abi.encodePacked(name));
        ISkaleDKG skaleDKG = ISkaleDKG(contractManager.getContract("SkaleDKG"));
        require(!skaleDKG.isLastDKGSuccessful(schainId), "DKG success");
        SchainsInternal schainsInternal = SchainsInternal(
            contractManager.getContract("SchainsInternal"));
        require(schainsInternal.isAnyFreeNode(schainId), "No free Nodes for new group formation");
        uint newNodeIndex = nodeRotation.selectNodeToGroup(schainId);
        skaleDKG.openChannel(schainId);
        emit NodeAdded(schainId, newNodeIndex);
    }

    /**
     * @dev addSpace - return occupied space to Node
     * nodeIndex - index of Node at common array of Nodes
     * partOfNode - divisor of given type of Schain
     */
    function addSpace(uint nodeIndex, uint8 partOfNode) external allowTwo("Schains", "NodeRotation") {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        nodes.addSpaceToNode(nodeIndex, partOfNode);
    }

    /**
     * @dev Checks whether schain group signature is valid.
     */
    function verifySchainSignature(
        uint signatureA,
        uint signatureB,
        bytes32 hash,
        uint counter,
        uint hashA,
        uint hashB,
        string calldata schainName
    )
        external
        view
        returns (bool)
    {
        SkaleVerifier skaleVerifier = SkaleVerifier(contractManager.getContract("SkaleVerifier"));
        G2Operations.G2Point memory publicKey = KeyStorage(
            contractManager.getContract("KeyStorage")
        ).getCommonPublicKey(
            keccak256(abi.encodePacked(schainName))
        );
        return skaleVerifier.verify(
            Fp2Operations.Fp2Point({
                a: signatureA,
                b: signatureB
            }),
            hash, counter,
            hashA, hashB,
            publicKey
        );
    }

    function initialize(address newContractsAddress) public override initializer {
        Permissions.initialize(newContractsAddress);
    }

    /**
     * @dev Returns the current price in SKL tokens for given Schain type and lifetime.
     */
    function getSchainPrice(uint typeOfSchain, uint lifetime) public view returns (uint) {
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getConstantsHolder());
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        uint nodeDeposit = constantsHolder.NODE_DEPOSIT();
        uint numberOfNodes;
        uint8 divisor;
        (divisor, numberOfNodes) = schainsInternal.getSchainType(typeOfSchain);
        if (divisor == 0) {
            return 1e18;
        } else {
            uint up = nodeDeposit.mul(numberOfNodes.mul(lifetime.mul(2)));
            uint down = uint(
                uint(constantsHolder.SMALL_DIVISOR())
                    .mul(uint(constantsHolder.SECONDS_TO_YEAR()))
                    .div(divisor)
            );
            return up.div(down);
        }
    }


    /**
     * @dev Initializes an schain in the SchainsInternal contract.
     * 
     * Requirements:
     * 
     * - Schain name is not already in use.
     */
    function _initializeSchainInSchainsInternal(
        string memory name,
        address from,
        uint deposit,
        uint lifetime,
        SchainsInternal schainsInternal
    )
        private
    {
        require(schainsInternal.isSchainNameAvailable(name), "Schain name is not available");

        // initialize Schain
        schainsInternal.initializeSchain(name, from, lifetime, deposit);
        schainsInternal.setSchainIndex(keccak256(abi.encodePacked(name)), from);
    }

    /**
     * @dev Converts data from bytes to normal schain parameters of lifetime,
     * type, nonce, and name.
     */
    function _fallbackSchainParametersDataConverter(bytes memory data)
        private
        pure
        returns (SchainParameters memory schainParameters)
    {
        (schainParameters.lifetime,
        schainParameters.typeOfSchain,
        schainParameters.nonce,
        schainParameters.name) = abi.decode(data, (uint, uint8, uint16, string));
    }

    /**
     * @dev Allows creation of node group for Schain.
     * 
     * Emits an {SchainNodes} event.
     */
    function _createGroupForSchain(
        string memory schainName,
        bytes32 schainId,
        uint numberOfNodes,
        uint8 partOfNode,
        SchainsInternal schainsInternal
    )
        private
    {
        uint[] memory nodesInGroup = schainsInternal.createGroupForSchain(schainId, numberOfNodes, partOfNode);
        ISkaleDKG(contractManager.getContract("SkaleDKG")).openChannel(schainId);

        emit SchainNodes(
            schainName,
            schainId,
            nodesInGroup,
            block.timestamp,
            gasleft());
    }

    /**
     * @dev Creates an schain.
     * 
     * Emits an {SchainCreated} event.
     * 
     * Requirements:
     * 
     * - Schain type must be valid.
     */
    function _addSchain(address from, uint deposit, SchainParameters memory schainParameters) private {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));

        //initialize Schain
        _initializeSchainInSchainsInternal(
            schainParameters.name,
            from,
            deposit,
            schainParameters.lifetime,
            schainsInternal
        );

        // create a group for Schain
        uint numberOfNodes;
        uint8 partOfNode;
        (partOfNode, numberOfNodes) = schainsInternal.getSchainType(schainParameters.typeOfSchain);

        _createGroupForSchain(
            schainParameters.name,
            keccak256(abi.encodePacked(schainParameters.name)),
            numberOfNodes,
            partOfNode,
            schainsInternal
        );

        emit SchainCreated(
            schainParameters.name,
            from,
            partOfNode,
            schainParameters.lifetime,
            numberOfNodes,
            deposit,
            schainParameters.nonce,
            keccak256(abi.encodePacked(schainParameters.name)),
            block.timestamp,
            gasleft());
    }

    function _deleteSchain(string calldata name, SchainsInternal schainsInternal) private {
        NodeRotation nodeRotation = NodeRotation(contractManager.getContract("NodeRotation"));

        bytes32 schainId = keccak256(abi.encodePacked(name));
        require(schainsInternal.isSchainExist(schainId), "Schain does not exist");

        uint[] memory nodesInGroup = schainsInternal.getNodesInGroup(schainId);
        uint8 partOfNode = schainsInternal.getSchainsPartOfNode(schainId);
        for (uint i = 0; i < nodesInGroup.length; i++) {
            uint schainIndex = schainsInternal.findSchainAtSchainsForNode(
                nodesInGroup[i],
                schainId
            );
            if (schainsInternal.checkHoleForSchain(schainId, i)) {
                continue;
            }
            require(
                schainIndex < schainsInternal.getLengthOfSchainsForNode(nodesInGroup[i]),
                "Some Node does not contain given Schain");
            schainsInternal.removeNodeFromSchain(nodesInGroup[i], schainId);
            schainsInternal.removeNodeFromExceptions(schainId, nodesInGroup[i]);
            this.addSpace(nodesInGroup[i], partOfNode);
        }
        schainsInternal.deleteGroup(schainId);
        address from = schainsInternal.getSchainOwner(schainId);
        schainsInternal.removeSchain(schainId, from);
        schainsInternal.removeHolesForSchain(schainId);
        nodeRotation.removeRotation(schainId);
        Wallets(payable(contractManager.getContract("Wallets"))).withdrawFundsFromSchainWallet(payable(from), schainId);
        emit SchainDeleted(from, name, schainId);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SchainsInternal.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "./interfaces/ISkaleDKG.sol";
import "./utils/Random.sol";

import "./ConstantsHolder.sol";
import "./Nodes.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/utils/EnumerableSet.sol";

/**
 * @title SchainsInternal
 * @dev Contract contains all functionality logic to internally manage Schains.
 */
contract SchainsInternal is Permissions {

    using Random for Random.RandomGenerator;
    using EnumerableSet for EnumerableSet.UintSet;

    struct Schain {
        string name;
        address owner;
        uint indexInOwnerList;
        uint8 partOfNode;
        uint lifetime;
        uint startDate;
        uint startBlock;
        uint deposit;
        uint64 index;
    }

    struct SchainType {
        uint8 partOfNode;
        uint numberOfNodes;
    }


    // mapping which contain all schains
    mapping (bytes32 => Schain) public schains;

    mapping (bytes32 => bool) public isSchainActive;

    mapping (bytes32 => uint[]) public schainsGroups;

    mapping (bytes32 => mapping (uint => bool)) private _exceptionsForGroups;
    // mapping shows schains by owner's address
    mapping (address => bytes32[]) public schainIndexes;
    // mapping shows schains which Node composed in
    mapping (uint => bytes32[]) public schainsForNodes;

    mapping (uint => uint[]) public holesForNodes;

    mapping (bytes32 => uint[]) public holesForSchains;

    // array which contain all schains
    bytes32[] public schainsAtSystem;

    uint64 public numberOfSchains;
    // total resources that schains occupied
    uint public sumOfSchainsResources;

    mapping (bytes32 => bool) public usedSchainNames;

    mapping (uint => SchainType) public schainTypes;
    uint public numberOfSchainTypes;

    //   schain hash =>   node index  => index of place
    // index of place is a number from 1 to max number of slots on node(128)
    mapping (bytes32 => mapping (uint => uint)) public placeOfSchainOnNode;

    mapping (uint => bytes32[]) private _nodeToLockedSchains;

    mapping (bytes32 => uint[]) private _schainToExceptionNodes;

    EnumerableSet.UintSet private _keysOfSchainTypes;

    /**
     * @dev Allows Schain contract to initialize an schain.
     */
    function initializeSchain(
        string calldata name,
        address from,
        uint lifetime,
        uint deposit) external allow("Schains")
    {
        bytes32 schainId = keccak256(abi.encodePacked(name));
        schains[schainId].name = name;
        schains[schainId].owner = from;
        schains[schainId].startDate = block.timestamp;
        schains[schainId].startBlock = block.number;
        schains[schainId].lifetime = lifetime;
        schains[schainId].deposit = deposit;
        schains[schainId].index = numberOfSchains;
        isSchainActive[schainId] = true;
        numberOfSchains++;
        schainsAtSystem.push(schainId);
        usedSchainNames[schainId] = true;
    }

    /**
     * @dev Allows Schain contract to create a node group for an schain.
     */
    function createGroupForSchain(
        bytes32 schainId,
        uint numberOfNodes,
        uint8 partOfNode
    )
        external
        allow("Schains")
        returns (uint[] memory)
    {
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getContract("ConstantsHolder"));
        schains[schainId].partOfNode = partOfNode;
        if (partOfNode > 0) {
            sumOfSchainsResources = sumOfSchainsResources.add(
                numberOfNodes.mul(constantsHolder.TOTAL_SPACE_ON_NODE()).div(partOfNode)
            );
        }
        return _generateGroup(schainId, numberOfNodes);
    }

    /**
     * @dev Allows Schains contract to set index in owner list.
     */
    function setSchainIndex(bytes32 schainId, address from) external allow("Schains") {
        schains[schainId].indexInOwnerList = schainIndexes[from].length;
        schainIndexes[from].push(schainId);
    }

    /**
     * @dev Allows Schains contract to change the Schain lifetime through
     * an additional SKL token deposit.
     */
    function changeLifetime(bytes32 schainId, uint lifetime, uint deposit) external allow("Schains") {
        schains[schainId].deposit = schains[schainId].deposit.add(deposit);
        schains[schainId].lifetime = schains[schainId].lifetime.add(lifetime);
    }

    /**
     * @dev Allows Schains contract to remove an schain from the network.
     * Generally schains are not removed from the system; instead they are
     * simply allowed to expire.
     */
    function removeSchain(bytes32 schainId, address from) external allow("Schains") {
        isSchainActive[schainId] = false;
        uint length = schainIndexes[from].length;
        uint index = schains[schainId].indexInOwnerList;
        if (index != length.sub(1)) {
            bytes32 lastSchainId = schainIndexes[from][length.sub(1)];
            schains[lastSchainId].indexInOwnerList = index;
            schainIndexes[from][index] = lastSchainId;
        }
        schainIndexes[from].pop();

        // TODO:
        // optimize
        for (uint i = 0; i + 1 < schainsAtSystem.length; i++) {
            if (schainsAtSystem[i] == schainId) {
                schainsAtSystem[i] = schainsAtSystem[schainsAtSystem.length.sub(1)];
                break;
            }
        }
        schainsAtSystem.pop();

        delete schains[schainId];
        numberOfSchains--;
    }

    /**
     * @dev Allows Schains and SkaleDKG contracts to remove a node from an
     * schain for node rotation or DKG failure.
     */
    function removeNodeFromSchain(
        uint nodeIndex,
        bytes32 schainHash
    )
        external
        allowThree("NodeRotation", "SkaleDKG", "Schains")
    {
        uint indexOfNode = _findNode(schainHash, nodeIndex);
        uint indexOfLastNode = schainsGroups[schainHash].length.sub(1);

        if (indexOfNode == indexOfLastNode) {
            schainsGroups[schainHash].pop();
        } else {
            delete schainsGroups[schainHash][indexOfNode];
            if (holesForSchains[schainHash].length > 0 && holesForSchains[schainHash][0] > indexOfNode) {
                uint hole = holesForSchains[schainHash][0];
                holesForSchains[schainHash][0] = indexOfNode;
                holesForSchains[schainHash].push(hole);
            } else {
                holesForSchains[schainHash].push(indexOfNode);
            }
        }

        uint schainIndexOnNode = findSchainAtSchainsForNode(nodeIndex, schainHash);
        removeSchainForNode(nodeIndex, schainIndexOnNode);
        delete placeOfSchainOnNode[schainHash][nodeIndex];
    }

    /**
     * @dev Allows Schains contract to delete a group of schains
     */
    function deleteGroup(bytes32 schainId) external allow("Schains") {
        // delete channel
        ISkaleDKG skaleDKG = ISkaleDKG(contractManager.getContract("SkaleDKG"));
        delete schainsGroups[schainId];
        skaleDKG.deleteChannel(schainId);
    }

    /**
     * @dev Allows Schain and NodeRotation contracts to set a Node like
     * exception for a given schain and nodeIndex.
     */
    function setException(bytes32 schainId, uint nodeIndex) external allowTwo("Schains", "NodeRotation") {
        _setException(schainId, nodeIndex);
    }

    /**
     * @dev Allows Schains and NodeRotation contracts to add node to an schain
     * group.
     */
    function setNodeInGroup(bytes32 schainId, uint nodeIndex) external allowTwo("Schains", "NodeRotation") {
        if (holesForSchains[schainId].length == 0) {
            schainsGroups[schainId].push(nodeIndex);
        } else {
            schainsGroups[schainId][holesForSchains[schainId][0]] = nodeIndex;
            uint min = uint(-1);
            uint index = 0;
            for (uint i = 1; i < holesForSchains[schainId].length; i++) {
                if (min > holesForSchains[schainId][i]) {
                    min = holesForSchains[schainId][i];
                    index = i;
                }
            }
            if (min == uint(-1)) {
                delete holesForSchains[schainId];
            } else {
                holesForSchains[schainId][0] = min;
                holesForSchains[schainId][index] =
                    holesForSchains[schainId][holesForSchains[schainId].length - 1];
                holesForSchains[schainId].pop();
            }
        }
    }

    /**
     * @dev Allows Schains contract to remove holes for schains
     */
    function removeHolesForSchain(bytes32 schainHash) external allow("Schains") {
        delete holesForSchains[schainHash];
    }

    /**
     * @dev Allows Admin to add schain type
     */
    function addSchainType(uint8 partOfNode, uint numberOfNodes) external onlyAdmin {
        require(_keysOfSchainTypes.add(numberOfSchainTypes + 1), "Schain type is already added");
        schainTypes[numberOfSchainTypes + 1].partOfNode = partOfNode;
        schainTypes[numberOfSchainTypes + 1].numberOfNodes = numberOfNodes;
        numberOfSchainTypes++;
    }

    /**
     * @dev Allows Admin to remove schain type
     */
    function removeSchainType(uint typeOfSchain) external onlyAdmin {
        require(_keysOfSchainTypes.remove(typeOfSchain), "Schain type is already removed");
        delete schainTypes[typeOfSchain].partOfNode;
        delete schainTypes[typeOfSchain].numberOfNodes;
    }

    /**
     * @dev Allows Admin to set number of schain types
     */
    function setNumberOfSchainTypes(uint newNumberOfSchainTypes) external onlyAdmin {
        numberOfSchainTypes = newNumberOfSchainTypes;
    }

    /**
     * @dev Allows Admin to move schain to placeOfSchainOnNode map
     */
    function moveToPlaceOfSchainOnNode(bytes32 schainHash) external onlyAdmin {
        for (uint i = 0; i < schainsGroups[schainHash].length; i++) {
            uint nodeIndex = schainsGroups[schainHash][i];
            for (uint j = 0; j < schainsForNodes[nodeIndex].length; j++) {
                if (schainsForNodes[nodeIndex][j] == schainHash) {
                    placeOfSchainOnNode[schainHash][nodeIndex] = j + 1;
                }
            }
        }
    }

    function removeNodeFromAllExceptionSchains(uint nodeIndex) external allow("SkaleManager") {
        uint len = _nodeToLockedSchains[nodeIndex].length;
        if (len > 0) {
            for (uint i = len; i > 0; i--) {
                removeNodeFromExceptions(_nodeToLockedSchains[nodeIndex][i - 1], nodeIndex);
            }
        }
    }

    function makeSchainNodesInvisible(bytes32 schainId) external allowTwo("NodeRotation", "SkaleDKG") {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        for (uint i = 0; i < _schainToExceptionNodes[schainId].length; i++) {
            nodes.makeNodeInvisible(_schainToExceptionNodes[schainId][i]);
        }
    }

    function makeSchainNodesVisible(bytes32 schainId) external allowTwo("NodeRotation", "SkaleDKG") {
        _makeSchainNodesVisible(schainId);
    }

    /**
     * @dev Returns all Schains in the network.
     */
    function getSchains() external view returns (bytes32[] memory) {
        return schainsAtSystem;
    }

    /**
     * @dev Returns all occupied resources on one node for an Schain.
     */
    function getSchainsPartOfNode(bytes32 schainId) external view returns (uint8) {
        return schains[schainId].partOfNode;
    }

    /**
     * @dev Returns number of schains by schain owner.
     */
    function getSchainListSize(address from) external view returns (uint) {
        return schainIndexes[from].length;
    }

    /**
     * @dev Returns hashes of schain names by schain owner.
     */
    function getSchainIdsByAddress(address from) external view returns (bytes32[] memory) {
        return schainIndexes[from];
    }

    /**
     * @dev Returns hashes of schain names running on a node.
     */
    function getSchainIdsForNode(uint nodeIndex) external view returns (bytes32[] memory) {
        return schainsForNodes[nodeIndex];
    }

    /**
     * @dev Returns the owner of an schain.
     */
    function getSchainOwner(bytes32 schainId) external view returns (address) {
        return schains[schainId].owner;
    }

    /**
     * @dev Checks whether schain name is available.
     * TODO Need to delete - copy of web3.utils.soliditySha3
     */
    function isSchainNameAvailable(string calldata name) external view returns (bool) {
        bytes32 schainId = keccak256(abi.encodePacked(name));
        return schains[schainId].owner == address(0) &&
            !usedSchainNames[schainId] &&
            keccak256(abi.encodePacked(name)) != keccak256(abi.encodePacked("Mainnet"));
    }

    /**
     * @dev Checks whether schain lifetime has expired.
     */
    function isTimeExpired(bytes32 schainId) external view returns (bool) {
        return uint(schains[schainId].startDate).add(schains[schainId].lifetime) < block.timestamp;
    }

    /**
     * @dev Checks whether address is owner of schain.
     */
    function isOwnerAddress(address from, bytes32 schainId) external view returns (bool) {
        return schains[schainId].owner == from;
    }

    /**
     * @dev Checks whether schain exists.
     */
    function isSchainExist(bytes32 schainId) external view returns (bool) {
        return keccak256(abi.encodePacked(schains[schainId].name)) != keccak256(abi.encodePacked(""));
    }

    /**
     * @dev Returns schain name.
     */
    function getSchainName(bytes32 schainId) external view returns (string memory) {
        return schains[schainId].name;
    }

    /**
     * @dev Returns last active schain of a node.
     */
    function getActiveSchain(uint nodeIndex) external view returns (bytes32) {
        for (uint i = schainsForNodes[nodeIndex].length; i > 0; i--) {
            if (schainsForNodes[nodeIndex][i - 1] != bytes32(0)) {
                return schainsForNodes[nodeIndex][i - 1];
            }
        }
        return bytes32(0);
    }

    /**
     * @dev Returns active schains of a node.
     */
    function getActiveSchains(uint nodeIndex) external view returns (bytes32[] memory activeSchains) {
        uint activeAmount = 0;
        for (uint i = 0; i < schainsForNodes[nodeIndex].length; i++) {
            if (schainsForNodes[nodeIndex][i] != bytes32(0)) {
                activeAmount++;
            }
        }

        uint cursor = 0;
        activeSchains = new bytes32[](activeAmount);
        for (uint i = schainsForNodes[nodeIndex].length; i > 0; i--) {
            if (schainsForNodes[nodeIndex][i - 1] != bytes32(0)) {
                activeSchains[cursor++] = schainsForNodes[nodeIndex][i - 1];
            }
        }
    }

    /**
     * @dev Returns number of nodes in an schain group.
     */
    function getNumberOfNodesInGroup(bytes32 schainId) external view returns (uint) {
        return schainsGroups[schainId].length;
    }

    /**
     * @dev Returns nodes in an schain group.
     */
    function getNodesInGroup(bytes32 schainId) external view returns (uint[] memory) {
        return schainsGroups[schainId];
    }

    /**
     * @dev Checks whether sender is a node address from a given schain group.
     */
    function isNodeAddressesInGroup(bytes32 schainId, address sender) external view returns (bool) {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        for (uint i = 0; i < schainsGroups[schainId].length; i++) {
            if (nodes.getNodeAddress(schainsGroups[schainId][i]) == sender) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Returns node index in schain group.
     */
    function getNodeIndexInGroup(bytes32 schainId, uint nodeId) external view returns (uint) {
        for (uint index = 0; index < schainsGroups[schainId].length; index++) {
            if (schainsGroups[schainId][index] == nodeId) {
                return index;
            }
        }
        return schainsGroups[schainId].length;
    }

    /**
     * @dev Checks whether there are any nodes with free resources for given
     * schain.
     */
    function isAnyFreeNode(bytes32 schainId) external view returns (bool) {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        uint8 space = schains[schainId].partOfNode;
        return nodes.countNodesWithFreeSpace(space) > 0;
    }

    /**
     * @dev Returns whether any exceptions exist for node in a schain group.
     */
    function checkException(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        return _exceptionsForGroups[schainId][nodeIndex];
    }

    function checkHoleForSchain(bytes32 schainHash, uint indexOfNode) external view returns (bool) {
        for (uint i = 0; i < holesForSchains[schainHash].length; i++) {
            if (holesForSchains[schainHash][i] == indexOfNode) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Returns number of Schains on a node.
     */
    function getLengthOfSchainsForNode(uint nodeIndex) external view returns (uint) {
        return schainsForNodes[nodeIndex].length;
    }

    function getSchainType(uint typeOfSchain) external view returns(uint8, uint) {
        require(_keysOfSchainTypes.contains(typeOfSchain), "Invalid type of schain");
        return (schainTypes[typeOfSchain].partOfNode, schainTypes[typeOfSchain].numberOfNodes);
    }

    function initialize(address newContractsAddress) public override initializer {
        Permissions.initialize(newContractsAddress);

        numberOfSchains = 0;
        sumOfSchainsResources = 0;
        numberOfSchainTypes = 0;
    }

    /**
     * @dev Allows Schains and NodeRotation contracts to add schain to node.
     */
    function addSchainForNode(uint nodeIndex, bytes32 schainId) public allowTwo("Schains", "NodeRotation") {
        if (holesForNodes[nodeIndex].length == 0) {
            schainsForNodes[nodeIndex].push(schainId);
            placeOfSchainOnNode[schainId][nodeIndex] = schainsForNodes[nodeIndex].length;
        } else {
            uint lastHoleOfNode = holesForNodes[nodeIndex][holesForNodes[nodeIndex].length - 1];
            schainsForNodes[nodeIndex][lastHoleOfNode] = schainId;
            placeOfSchainOnNode[schainId][nodeIndex] = lastHoleOfNode + 1;
            holesForNodes[nodeIndex].pop();
        }
    }

    /**
     * @dev Allows Schains, NodeRotation, and SkaleDKG contracts to remove an 
     * schain from a node.
     */
    function removeSchainForNode(uint nodeIndex, uint schainIndex)
        public
        allowThree("NodeRotation", "SkaleDKG", "Schains")
    {
        uint length = schainsForNodes[nodeIndex].length;
        if (schainIndex == length.sub(1)) {
            schainsForNodes[nodeIndex].pop();
        } else {
            delete schainsForNodes[nodeIndex][schainIndex];
            if (holesForNodes[nodeIndex].length > 0 && holesForNodes[nodeIndex][0] > schainIndex) {
                uint hole = holesForNodes[nodeIndex][0];
                holesForNodes[nodeIndex][0] = schainIndex;
                holesForNodes[nodeIndex].push(hole);
            } else {
                holesForNodes[nodeIndex].push(schainIndex);
            }
        }
    }

    /**
     * @dev Allows Schains contract to remove node from exceptions
     */
    function removeNodeFromExceptions(bytes32 schainHash, uint nodeIndex)
        public
        allowThree("Schains", "NodeRotation", "SkaleManager")
    {
        _exceptionsForGroups[schainHash][nodeIndex] = false;
        uint len = _nodeToLockedSchains[nodeIndex].length;
        bool removed = false;
        if (len > 0 && _nodeToLockedSchains[nodeIndex][len - 1] == schainHash) {
            _nodeToLockedSchains[nodeIndex].pop();
            removed = true;
        } else {
            for (uint i = len; i > 0 && !removed; i--) {
                if (_nodeToLockedSchains[nodeIndex][i - 1] == schainHash) {
                    _nodeToLockedSchains[nodeIndex][i - 1] = _nodeToLockedSchains[nodeIndex][len - 1];
                    _nodeToLockedSchains[nodeIndex].pop();
                    removed = true;
                }
            }
        }
        len = _schainToExceptionNodes[schainHash].length;
        removed = false;
        if (len > 0 && _schainToExceptionNodes[schainHash][len - 1] == nodeIndex) {
            _schainToExceptionNodes[schainHash].pop();
            removed = true;
        } else {
            for (uint i = len; i > 0 && !removed; i--) {
                if (_schainToExceptionNodes[schainHash][i - 1] == nodeIndex) {
                    _schainToExceptionNodes[schainHash][i - 1] = _schainToExceptionNodes[schainHash][len - 1];
                    _schainToExceptionNodes[schainHash].pop();
                    removed = true;
                }
            }
        }
    }

    /**
     * @dev Returns index of Schain in list of schains for a given node.
     */
    function findSchainAtSchainsForNode(uint nodeIndex, bytes32 schainId) public view returns (uint) {
        if (placeOfSchainOnNode[schainId][nodeIndex] == 0)
            return schainsForNodes[nodeIndex].length;
        return placeOfSchainOnNode[schainId][nodeIndex] - 1;
    }

    function _getNodeToLockedSchains() internal view returns (mapping(uint => bytes32[]) storage) {
        return _nodeToLockedSchains;
    }

    function _getSchainToExceptionNodes() internal view returns (mapping(bytes32 => uint[]) storage) {
        return _schainToExceptionNodes;
    }

    /**
     * @dev Generates schain group using a pseudo-random generator.
     */
    function _generateGroup(bytes32 schainId, uint numberOfNodes) private returns (uint[] memory nodesInGroup) {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        uint8 space = schains[schainId].partOfNode;
        nodesInGroup = new uint[](numberOfNodes);

        require(nodes.countNodesWithFreeSpace(space) >= nodesInGroup.length, "Not enough nodes to create Schain");
        Random.RandomGenerator memory randomGenerator = Random.createFromEntropy(
            abi.encodePacked(uint(blockhash(block.number.sub(1))), schainId)
        );
        for (uint i = 0; i < numberOfNodes; i++) {
            uint node = nodes.getRandomNodeWithFreeSpace(space, randomGenerator);
            nodesInGroup[i] = node;
            _setException(schainId, node);
            addSchainForNode(node, schainId);
            nodes.makeNodeInvisible(node);
            require(nodes.removeSpaceFromNode(node, space), "Could not remove space from Node");
        }
        // set generated group
        schainsGroups[schainId] = nodesInGroup;
        _makeSchainNodesVisible(schainId);
    }

    function _setException(bytes32 schainId, uint nodeIndex) private {
        _exceptionsForGroups[schainId][nodeIndex] = true;
        _nodeToLockedSchains[nodeIndex].push(schainId);
        _schainToExceptionNodes[schainId].push(nodeIndex);
    }

    function _makeSchainNodesVisible(bytes32 schainId) private {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        for (uint i = 0; i < _schainToExceptionNodes[schainId].length; i++) {
            nodes.makeNodeVisible(_schainToExceptionNodes[schainId][i]);
        }
    }

    /**
     * @dev Returns local index of node in schain group.
     */
    function _findNode(bytes32 schainId, uint nodeIndex) private view returns (uint) {
        uint[] memory nodesInGroup = schainsGroups[schainId];
        uint index;
        for (index = 0; index < nodesInGroup.length; index++) {
            if (nodesInGroup[index] == nodeIndex) {
                return index;
            }
        }
        return index;
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    FieldOperations.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs

    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

import "./Precompiled.sol";


library Fp2Operations {
    using SafeMath for uint;

    struct Fp2Point {
        uint a;
        uint b;
    }

    uint constant public P = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    function addFp2(Fp2Point memory value1, Fp2Point memory value2) internal pure returns (Fp2Point memory) {
        return Fp2Point({ a: addmod(value1.a, value2.a, P), b: addmod(value1.b, value2.b, P) });
    }

    function scalarMulFp2(Fp2Point memory value, uint scalar) internal pure returns (Fp2Point memory) {
        return Fp2Point({ a: mulmod(scalar, value.a, P), b: mulmod(scalar, value.b, P) });
    }

    function minusFp2(Fp2Point memory diminished, Fp2Point memory subtracted) internal pure
        returns (Fp2Point memory difference)
    {
        uint p = P;
        if (diminished.a >= subtracted.a) {
            difference.a = addmod(diminished.a, p - subtracted.a, p);
        } else {
            difference.a = (p - addmod(subtracted.a, p - diminished.a, p)).mod(p);
        }
        if (diminished.b >= subtracted.b) {
            difference.b = addmod(diminished.b, p - subtracted.b, p);
        } else {
            difference.b = (p - addmod(subtracted.b, p - diminished.b, p)).mod(p);
        }
    }

    function mulFp2(
        Fp2Point memory value1,
        Fp2Point memory value2
    )
        internal
        pure
        returns (Fp2Point memory result)
    {
        uint p = P;
        Fp2Point memory point = Fp2Point({
            a: mulmod(value1.a, value2.a, p),
            b: mulmod(value1.b, value2.b, p)});
        result.a = addmod(
            point.a,
            mulmod(p - 1, point.b, p),
            p);
        result.b = addmod(
            mulmod(
                addmod(value1.a, value1.b, p),
                addmod(value2.a, value2.b, p),
                p),
            p - addmod(point.a, point.b, p),
            p);
    }

    function squaredFp2(Fp2Point memory value) internal pure returns (Fp2Point memory) {
        uint p = P;
        uint ab = mulmod(value.a, value.b, p);
        uint mult = mulmod(addmod(value.a, value.b, p), addmod(value.a, mulmod(p - 1, value.b, p), p), p);
        return Fp2Point({ a: mult, b: addmod(ab, ab, p) });
    }

    function inverseFp2(Fp2Point memory value) internal view returns (Fp2Point memory result) {
        uint p = P;
        uint t0 = mulmod(value.a, value.a, p);
        uint t1 = mulmod(value.b, value.b, p);
        uint t2 = mulmod(p - 1, t1, p);
        if (t0 >= t2) {
            t2 = addmod(t0, p - t2, p);
        } else {
            t2 = (p - addmod(t2, p - t0, p)).mod(p);
        }
        uint t3 = Precompiled.bigModExp(t2, p - 2, p);
        result.a = mulmod(value.a, t3, p);
        result.b = (p - mulmod(value.b, t3, p)).mod(p);
    }

    function isEqual(
        Fp2Point memory value1,
        Fp2Point memory value2
    )
        internal
        pure
        returns (bool)
    {
        return value1.a == value2.a && value1.b == value2.b;
    }
}

library G1Operations {
    using SafeMath for uint;
    using Fp2Operations for Fp2Operations.Fp2Point;

    function getG1Generator() internal pure returns (Fp2Operations.Fp2Point memory) {
        // Current solidity version does not support Constants of non-value type
        // so we implemented this function
        return Fp2Operations.Fp2Point({
            a: 1,
            b: 2
        });
    }

    function isG1Point(uint x, uint y) internal pure returns (bool) {
        uint p = Fp2Operations.P;
        return mulmod(y, y, p) == 
            addmod(mulmod(mulmod(x, x, p), x, p), 3, p);
    }

    function isG1(Fp2Operations.Fp2Point memory point) internal pure returns (bool) {
        return isG1Point(point.a, point.b);
    }

    function checkRange(Fp2Operations.Fp2Point memory point) internal pure returns (bool) {
        return point.a < Fp2Operations.P && point.b < Fp2Operations.P;
    }

    function negate(uint y) internal pure returns (uint) {
        return Fp2Operations.P.sub(y).mod(Fp2Operations.P);
    }

}


library G2Operations {
    using SafeMath for uint;
    using Fp2Operations for Fp2Operations.Fp2Point;

    struct G2Point {
        Fp2Operations.Fp2Point x;
        Fp2Operations.Fp2Point y;
    }

    function getTWISTB() internal pure returns (Fp2Operations.Fp2Point memory) {
        // Current solidity version does not support Constants of non-value type
        // so we implemented this function
        return Fp2Operations.Fp2Point({
            a: 19485874751759354771024239261021720505790618469301721065564631296452457478373,
            b: 266929791119991161246907387137283842545076965332900288569378510910307636690
        });
    }

    function getG2Generator() internal pure returns (G2Point memory) {
        // Current solidity version does not support Constants of non-value type
        // so we implemented this function
        return G2Point({
            x: Fp2Operations.Fp2Point({
                a: 10857046999023057135944570762232829481370756359578518086990519993285655852781,
                b: 11559732032986387107991004021392285783925812861821192530917403151452391805634
            }),
            y: Fp2Operations.Fp2Point({
                a: 8495653923123431417604973247489272438418190587263600148770280649306958101930,
                b: 4082367875863433681332203403145435568316851327593401208105741076214120093531
            })
        });
    }

    function getG2Zero() internal pure returns (G2Point memory) {
        // Current solidity version does not support Constants of non-value type
        // so we implemented this function
        return G2Point({
            x: Fp2Operations.Fp2Point({
                a: 0,
                b: 0
            }),
            y: Fp2Operations.Fp2Point({
                a: 1,
                b: 0
            })
        });
    }

    function isG2Point(Fp2Operations.Fp2Point memory x, Fp2Operations.Fp2Point memory y) internal pure returns (bool) {
        if (isG2ZeroPoint(x, y)) {
            return true;
        }
        Fp2Operations.Fp2Point memory squaredY = y.squaredFp2();
        Fp2Operations.Fp2Point memory res = squaredY.minusFp2(
                x.squaredFp2().mulFp2(x)
            ).minusFp2(getTWISTB());
        return res.a == 0 && res.b == 0;
    }

    function isG2(G2Point memory value) internal pure returns (bool) {
        return isG2Point(value.x, value.y);
    }

    function isG2ZeroPoint(
        Fp2Operations.Fp2Point memory x,
        Fp2Operations.Fp2Point memory y
    )
        internal
        pure
        returns (bool)
    {
        return x.a == 0 && x.b == 0 && y.a == 1 && y.b == 0;
    }

    function isG2Zero(G2Point memory value) internal pure returns (bool) {
        return value.x.a == 0 && value.x.b == 0 && value.y.a == 1 && value.y.b == 0;
        // return isG2ZeroPoint(value.x, value.y);
    }

    function addG2(
        G2Point memory value1,
        G2Point memory value2
    )
        internal
        view
        returns (G2Point memory sum)
    {
        if (isG2Zero(value1)) {
            return value2;
        }
        if (isG2Zero(value2)) {
            return value1;
        }
        if (isEqual(value1, value2)) {
            return doubleG2(value1);
        }

        Fp2Operations.Fp2Point memory s = value2.y.minusFp2(value1.y).mulFp2(value2.x.minusFp2(value1.x).inverseFp2());
        sum.x = s.squaredFp2().minusFp2(value1.x.addFp2(value2.x));
        sum.y = value1.y.addFp2(s.mulFp2(sum.x.minusFp2(value1.x)));
        uint p = Fp2Operations.P;
        sum.y.a = (p - sum.y.a).mod(p);
        sum.y.b = (p - sum.y.b).mod(p);
    }

    function isEqual(
        G2Point memory value1,
        G2Point memory value2
    )
        internal
        pure
        returns (bool)
    {
        return value1.x.isEqual(value2.x) && value1.y.isEqual(value2.y);
    }

    function doubleG2(G2Point memory value)
        internal
        view
        returns (G2Point memory result)
    {
        if (isG2Zero(value)) {
            return value;
        } else {
            Fp2Operations.Fp2Point memory s =
                value.x.squaredFp2().scalarMulFp2(3).mulFp2(value.y.scalarMulFp2(2).inverseFp2());
            result.x = s.squaredFp2().minusFp2(value.x.addFp2(value.x));
            result.y = value.y.addFp2(s.mulFp2(result.x.minusFp2(value.x)));
            uint p = Fp2Operations.P;
            result.y.a = (p - result.y.a).mod(p);
            result.y.b = (p - result.y.b).mod(p);
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    NodeRotation.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "./interfaces/ISkaleDKG.sol";
import "./utils/Random.sol";

import "./ConstantsHolder.sol";
import "./Nodes.sol";
import "./Permissions.sol";
import "./SchainsInternal.sol";
import "./Schains.sol";


/**
 * @title NodeRotation
 * @dev This contract handles all node rotation functionality.
 */
contract NodeRotation is Permissions {
    using Random for Random.RandomGenerator;

    /**
     * nodeIndex - index of Node which is in process of rotation (left from schain)
     * newNodeIndex - index of Node which is rotated(added to schain)
     * freezeUntil - time till which Node should be turned on
     * rotationCounter - how many rotations were on this schain
     */
    struct Rotation {
        uint nodeIndex;
        uint newNodeIndex;
        uint freezeUntil;
        uint rotationCounter;
    }

    struct LeavingHistory {
        bytes32 schainIndex;
        uint finishedRotation;
    }

    mapping (bytes32 => Rotation) public rotations;

    mapping (uint => LeavingHistory[]) public leavingHistory;

    mapping (bytes32 => bool) public waitForNewNode;


    /**
     * @dev Allows SkaleManager to remove, find new node, and rotate node from 
     * schain.
     * 
     * Requirements:
     * 
     * - A free node must exist.
     */
    function exitFromSchain(uint nodeIndex) external allow("SkaleManager") returns (bool, bool) {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        bytes32 schainId = schainsInternal.getActiveSchain(nodeIndex);
        if (schainId == bytes32(0)) {
            return (true, false);
        }
        _startRotation(schainId, nodeIndex);
        rotateNode(nodeIndex, schainId, true, false);
        return (schainsInternal.getActiveSchain(nodeIndex) == bytes32(0) ? true : false, true);
    }

    /**
     * @dev Allows SkaleManager contract to freeze all schains on a given node.
     */
    function freezeSchains(uint nodeIndex) external allow("SkaleManager") {
        bytes32[] memory schains = SchainsInternal(
            contractManager.getContract("SchainsInternal")
        ).getSchainIdsForNode(nodeIndex);
        for (uint i = 0; i < schains.length; i++) {
            if (schains[i] != bytes32(0)) {
                require(
                    ISkaleDKG(contractManager.getContract("SkaleDKG")).isLastDKGSuccessful(schains[i]),
                    "DKG did not finish on Schain"
                );
                if (rotations[schains[i]].freezeUntil < now) {
                    _startWaiting(schains[i], nodeIndex);
                } else {
                    if (rotations[schains[i]].nodeIndex != nodeIndex) {
                        revert("Occupied by rotation on Schain");
                    }
                }
            }
        }
    }

    /**
     * @dev Allows Schains contract to remove a rotation from an schain.
     */
    function removeRotation(bytes32 schainIndex) external allow("Schains") {
        delete rotations[schainIndex];
    }

    /**
     * @dev Allows Owner to immediately rotate an schain.
     */
    function skipRotationDelay(bytes32 schainIndex) external onlyOwner {
        rotations[schainIndex].freezeUntil = now;
    }

    /**
     * @dev Returns rotation details for a given schain.
     */
    function getRotation(bytes32 schainIndex) external view returns (Rotation memory) {
        return rotations[schainIndex];
    }

    /**
     * @dev Returns leaving history for a given node.
     */
    function getLeavingHistory(uint nodeIndex) external view returns (LeavingHistory[] memory) {
        return leavingHistory[nodeIndex];
    }

    function isRotationInProgress(bytes32 schainIndex) external view returns (bool) {
        return rotations[schainIndex].freezeUntil >= now && !waitForNewNode[schainIndex];
    }

    function initialize(address newContractsAddress) public override initializer {
        Permissions.initialize(newContractsAddress);
    }

    /**
     * @dev Allows SkaleDKG and SkaleManager contracts to rotate a node from an
     * schain.
     */
    function rotateNode(
        uint nodeIndex,
        bytes32 schainId,
        bool shouldDelay,
        bool isBadNode
    )
        public
        allowTwo("SkaleDKG", "SkaleManager")
        returns (uint newNode)
    {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        schainsInternal.removeNodeFromSchain(nodeIndex, schainId);
        if (!isBadNode) {
            schainsInternal.removeNodeFromExceptions(schainId, nodeIndex);
        }
        newNode = selectNodeToGroup(schainId);
        Nodes(contractManager.getContract("Nodes")).addSpaceToNode(
            nodeIndex,
            schainsInternal.getSchainsPartOfNode(schainId)
        );
        _finishRotation(schainId, nodeIndex, newNode, shouldDelay);
    }

    /**
     * @dev Allows SkaleManager, Schains, and SkaleDKG contracts to 
     * pseudo-randomly select a new Node for an Schain.
     * 
     * Requirements:
     * 
     * - Schain is active.
     * - A free node already exists.
     * - Free space can be allocated from the node.
     */
    function selectNodeToGroup(bytes32 schainId)
        public
        allowThree("SkaleManager", "Schains", "SkaleDKG")
        returns (uint nodeIndex)
    {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        require(schainsInternal.isSchainActive(schainId), "Group is not active");
        uint8 space = schainsInternal.getSchainsPartOfNode(schainId);
        schainsInternal.makeSchainNodesInvisible(schainId);
        require(schainsInternal.isAnyFreeNode(schainId), "No free Nodes available for rotation");
        Random.RandomGenerator memory randomGenerator = Random.createFromEntropy(
            abi.encodePacked(uint(blockhash(block.number - 1)), schainId)
        );
        nodeIndex = nodes.getRandomNodeWithFreeSpace(space, randomGenerator);
        require(nodes.removeSpaceFromNode(nodeIndex, space), "Could not remove space from nodeIndex");
        schainsInternal.makeSchainNodesVisible(schainId);
        schainsInternal.addSchainForNode(nodeIndex, schainId);
        schainsInternal.setException(schainId, nodeIndex);
        schainsInternal.setNodeInGroup(schainId, nodeIndex);
    }


    /**
     * @dev Initiates rotation of a node from an schain.
     */
    function _startRotation(bytes32 schainIndex, uint nodeIndex) private {
        rotations[schainIndex].newNodeIndex = nodeIndex;
        waitForNewNode[schainIndex] = true;
    }

    function _startWaiting(bytes32 schainIndex, uint nodeIndex) private {
        ConstantsHolder constants = ConstantsHolder(contractManager.getContract("ConstantsHolder"));
        rotations[schainIndex].nodeIndex = nodeIndex;
        rotations[schainIndex].freezeUntil = now.add(constants.rotationDelay());
    }

    /**
     * @dev Completes rotation of a node from an schain.
     */
    function _finishRotation(
        bytes32 schainIndex,
        uint nodeIndex,
        uint newNodeIndex,
        bool shouldDelay)
        private
    {
        leavingHistory[nodeIndex].push(
            LeavingHistory(
                schainIndex,
                shouldDelay ? now.add(
                    ConstantsHolder(contractManager.getContract("ConstantsHolder")).rotationDelay()
                ) : now
            )
        );
        rotations[schainIndex].newNodeIndex = newNodeIndex;
        rotations[schainIndex].rotationCounter++;
        delete waitForNewNode[schainIndex];
        ISkaleDKG(contractManager.getContract("SkaleDKG")).openChannel(schainIndex);
    }

    /**
     * @dev Checks whether a rotation can be performed.
     * 
     * Requirements:
     * 
     * - Schain must exist.
     */
    function _checkRotation(bytes32 schainId ) private view returns (bool) {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));
        require(schainsInternal.isSchainExist(schainId), "Schain does not exist for rotation");
        return schainsInternal.isAnyFreeNode(schainId);
    }


}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    ISkaleDKG.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

/**
 * @dev Interface to {SkaleDKG}.
 */
interface ISkaleDKG {

    /**
     * @dev See {SkaleDKG-openChannel}.
     */
    function openChannel(bytes32 schainId) external;

    /**
     * @dev See {SkaleDKG-deleteChannel}.
     */
    function deleteChannel(bytes32 schainId) external;

    /**
     * @dev See {SkaleDKG-isLastDKGSuccessful}.
     */
    function isLastDKGSuccessful(bytes32 groupIndex) external view returns (bool);
    
    /**
     * @dev See {SkaleDKG-isChannelOpened}.
     */
    function isChannelOpened(bytes32 schainId) external view returns (bool);
}

// SPDX-License-Identifier: GPL-3.0-or-later

/*
    Modifications Copyright (C) 2018 SKALE Labs
    ec.sol by @jbaylina under GPL-3.0 License
*/
/** @file ECDH.sol
 * @author Jordi Baylina (@jbaylina)
 * @date 2016
 */

pragma solidity 0.6.10;
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";


/**
 * @title ECDH
 * @dev This contract performs Elliptic-curve Diffie-Hellman key exchange to
 * support the DKG process.
 */
contract ECDH {
    using SafeMath for uint256;

    uint256 constant private _GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 constant private _GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    uint256 constant private _N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 constant private _A  = 0;

    function publicKey(uint256 privKey) external pure returns (uint256 qx, uint256 qy) {
        uint256 x;
        uint256 y;
        uint256 z;
        (x, y, z) = ecMul(
            privKey,
            _GX,
            _GY,
            1
        );
        z = inverse(z);
        qx = mulmod(x, z, _N);
        qy = mulmod(y, z, _N);
    }

    function deriveKey(
        uint256 privKey,
        uint256 pubX,
        uint256 pubY
    )
        external
        pure
        returns (uint256 qx, uint256 qy)
    {
        uint256 x;
        uint256 y;
        uint256 z;
        (x, y, z) = ecMul(
            privKey,
            pubX,
            pubY,
            1
        );
        z = inverse(z);
        qx = mulmod(x, z, _N);
        qy = mulmod(y, z, _N);
    }

    function jAdd(
        uint256 x1,
        uint256 z1,
        uint256 x2,
        uint256 z2
    )
        public
        pure
        returns (uint256 x3, uint256 z3)
    {
        (x3, z3) = (addmod(mulmod(z2, x1, _N), mulmod(x2, z1, _N), _N), mulmod(z1, z2, _N));
    }

    function jSub(
        uint256 x1,
        uint256 z1,
        uint256 x2,
        uint256 z2
    )
        public
        pure
        returns (uint256 x3, uint256 z3)
    {
        (x3, z3) = (addmod(mulmod(z2, x1, _N), mulmod(_N.sub(x2), z1, _N), _N), mulmod(z1, z2, _N));
    }

    function jMul(
        uint256 x1,
        uint256 z1,
        uint256 x2,
        uint256 z2
    )
        public
        pure
        returns (uint256 x3, uint256 z3)
    {
        (x3, z3) = (mulmod(x1, x2, _N), mulmod(z1, z2, _N));
    }

    function jDiv(
        uint256 x1,
        uint256 z1,
        uint256 x2,
        uint256 z2
    )
        public
        pure
        returns (uint256 x3, uint256 z3)
    {
        (x3, z3) = (mulmod(x1, z2, _N), mulmod(z1, x2, _N));
    }

    function inverse(uint256 a) public pure returns (uint256 invA) {
        require(a > 0 && a < _N, "Input is incorrect");
        uint256 t = 0;
        uint256 newT = 1;
        uint256 r = _N;
        uint256 newR = a;
        uint256 q;
        while (newR != 0) {
            q = r.div(newR);
            (t, newT) = (newT, addmod(t, (_N.sub(mulmod(q, newT, _N))), _N));
            (r, newR) = (newR, r % newR);
        }
        return t;
    }

    function ecAdd(
        uint256 x1,
        uint256 y1,
        uint256 z1,
        uint256 x2,
        uint256 y2,
        uint256 z2
    )
        public
        pure
        returns (uint256 x3, uint256 y3, uint256 z3)
    {
        uint256 ln;
        uint256 lz;
        uint256 da;
        uint256 db;
        // we use (0 0 1) as zero point, z always equal 1
        if ((x1 == 0) && (y1 == 0)) {
            return (x2, y2, z2);
        }

        // we use (0 0 1) as zero point, z always equal 1
        if ((x2 == 0) && (y2 == 0)) {
            return (x1, y1, z1);
        }

        if ((x1 == x2) && (y1 == y2)) {
            (ln, lz) = jMul(x1, z1, x1, z1);
            (ln, lz) = jMul(ln,lz,3,1);
            (ln, lz) = jAdd(ln,lz,_A,1);
            (da, db) = jMul(y1,z1,2,1);
        } else {
            (ln, lz) = jSub(y2,z2,y1,z1);
            (da, db) = jSub(x2,z2,x1,z1);
        }
        (ln, lz) = jDiv(ln,lz,da,db);

        (x3, da) = jMul(ln,lz,ln,lz);
        (x3, da) = jSub(x3,da,x1,z1);
        (x3, da) = jSub(x3,da,x2,z2);

        (y3, db) = jSub(x1,z1,x3,da);
        (y3, db) = jMul(y3,db,ln,lz);
        (y3, db) = jSub(y3,db,y1,z1);

        if (da != db) {
            x3 = mulmod(x3, db, _N);
            y3 = mulmod(y3, da, _N);
            z3 = mulmod(da, db, _N);
        } else {
            z3 = da;
        }
    }

    function ecDouble(
        uint256 x1,
        uint256 y1,
        uint256 z1
    )
        public
        pure
        returns (uint256 x3, uint256 y3, uint256 z3)
    {
        (x3, y3, z3) = ecAdd(
            x1,
            y1,
            z1,
            x1,
            y1,
            z1
        );
    }

    function ecMul(
        uint256 d,
        uint256 x1,
        uint256 y1,
        uint256 z1
    )
        public
        pure
        returns (uint256 x3, uint256 y3, uint256 z3)
    {
        uint256 remaining = d;
        uint256 px = x1;
        uint256 py = y1;
        uint256 pz = z1;
        uint256 acx = 0;
        uint256 acy = 0;
        uint256 acz = 1;

        if (d == 0) {
            return (0, 0, 1);
        }

        while (remaining != 0) {
            if ((remaining & 1) != 0) {
                (acx, acy, acz) = ecAdd(
                    acx,
                    acy,
                    acz,
                    px,
                    py,
                    pz
                );
            }
            remaining = remaining.div(2);
            (px, py, pz) = ecDouble(px, py, pz);
        }

        (x3, y3, z3) = (acx, acy, acz);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Precompiled.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;


library Precompiled {

    function bigModExp(uint base, uint power, uint modulus) internal view returns (uint) {
        uint[6] memory inputToBigModExp;
        inputToBigModExp[0] = 32;
        inputToBigModExp[1] = 32;
        inputToBigModExp[2] = 32;
        inputToBigModExp[3] = base;
        inputToBigModExp[4] = power;
        inputToBigModExp[5] = modulus;
        uint[1] memory out;
        bool success;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            success := staticcall(not(0), 5, inputToBigModExp, mul(6, 0x20), out, 0x20)
        }
        require(success, "BigModExp failed");
        return out[0];
    }

    function bn256ScalarMul(uint x, uint y, uint k) internal view returns (uint , uint ) {
        uint[3] memory inputToMul;
        uint[2] memory output;
        inputToMul[0] = x;
        inputToMul[1] = y;
        inputToMul[2] = k;
        bool success;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            success := staticcall(not(0), 7, inputToMul, 0x60, output, 0x40)
        }
        require(success, "Multiplication failed");
        return (output[0], output[1]);
    }

    function bn256Pairing(
        uint x1,
        uint y1,
        uint a1,
        uint b1,
        uint c1,
        uint d1,
        uint x2,
        uint y2,
        uint a2,
        uint b2,
        uint c2,
        uint d2)
        internal view returns (bool)
    {
        bool success;
        uint[12] memory inputToPairing;
        inputToPairing[0] = x1;
        inputToPairing[1] = y1;
        inputToPairing[2] = a1;
        inputToPairing[3] = b1;
        inputToPairing[4] = c1;
        inputToPairing[5] = d1;
        inputToPairing[6] = x2;
        inputToPairing[7] = y2;
        inputToPairing[8] = a2;
        inputToPairing[9] = b2;
        inputToPairing[10] = c2;
        inputToPairing[11] = d2;
        uint[1] memory out;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            success := staticcall(not(0), 8, inputToPairing, mul(12, 0x20), out, 0x20)
        }
        require(success, "Pairing check failed");
        return out[0] != 0;
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDkgBroadcast.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "../SkaleDKG.sol";
import "../KeyStorage.sol";
import "../utils/FieldOperations.sol";


/**
 * @title SkaleDkgBroadcast
 * @dev Contains functions to manage distributed key generation per
 * Joint-Feldman protocol.
 */
library SkaleDkgBroadcast {
    using SafeMath for uint;

    /**
     * @dev Emitted when a node broadcasts keyshare.
     */
    event BroadcastAndKeyShare(
        bytes32 indexed schainId,
        uint indexed fromNode,
        G2Operations.G2Point[] verificationVector,
        SkaleDKG.KeyShare[] secretKeyContribution
    );


    /**
     * @dev Broadcasts verification vector and secret key contribution to all
     * other nodes in the group.
     *
     * Emits BroadcastAndKeyShare event.
     *
     * Requirements:
     *
     * - `msg.sender` must have an associated node.
     * - `verificationVector` must be a certain length.
     * - `secretKeyContribution` length must be equal to number of nodes in group.
     */
    function broadcast(
        bytes32 schainId,
        uint nodeIndex,
        G2Operations.G2Point[] memory verificationVector,
        SkaleDKG.KeyShare[] memory secretKeyContribution,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.Channel) storage channels,
        mapping(bytes32 => SkaleDKG.ProcessDKG) storage dkgProcess,
        mapping(bytes32 => mapping(uint => bytes32)) storage hashedData
    )
        external
    {
        uint n = channels[schainId].n;
        require(verificationVector.length == getT(n), "Incorrect number of verification vectors");
        require(
            secretKeyContribution.length == n,
            "Incorrect number of secret key shares"
        );
        (uint index, ) = SkaleDKG(contractManager.getContract("SkaleDKG")).checkAndReturnIndexInGroup(
            schainId, nodeIndex, true
        );
        require(!dkgProcess[schainId].broadcasted[index], "This node has already broadcasted");
        dkgProcess[schainId].broadcasted[index] = true;
        dkgProcess[schainId].numberOfBroadcasted++;
        if (dkgProcess[schainId].numberOfBroadcasted == channels[schainId].n) {
            SkaleDKG(contractManager.getContract("SkaleDKG")).setStartAlrightTimestamp(schainId);
        }
        hashedData[schainId][index] = SkaleDKG(contractManager.getContract("SkaleDKG")).hashData(
            secretKeyContribution, verificationVector
        );
        KeyStorage(contractManager.getContract("KeyStorage")).adding(schainId, verificationVector[0]);
        emit BroadcastAndKeyShare(
            schainId,
            nodeIndex,
            verificationVector,
            secretKeyContribution
        );
    }

    function getT(uint n) public pure returns (uint) {
        return n.mul(2).add(1).div(3);
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDkgComplaint.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "../SkaleDKG.sol";
import "../ConstantsHolder.sol";
import "../Wallets.sol";
import "../Nodes.sol";

/**
 * @title SkaleDkgComplaint
 * @dev Contains functions to manage distributed key generation per
 * Joint-Feldman protocol.
 */
library SkaleDkgComplaint {
    using SafeMath for uint;

    /**
     * @dev Emitted when an incorrect complaint is sent.
     */
    event ComplaintError(string error);

    /**
     * @dev Emitted when a complaint is sent.
     */
    event ComplaintSent(
        bytes32 indexed schainId, uint indexed fromNodeIndex, uint indexed toNodeIndex);


    /**
     * @dev Creates a complaint from a node (accuser) to a given node.
     * The accusing node must broadcast additional parameters within 1800 blocks.
     *
     * Emits {ComplaintSent} or {ComplaintError} event.
     *
     * Requirements:
     *
     * - `msg.sender` must have an associated node.
     */
    function complaint(
        bytes32 schainId,
        uint fromNodeIndex,
        uint toNodeIndex,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.Channel) storage channels,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints,
        mapping(bytes32 => uint) storage startAlrightTimestamp
    )
        external
    {
        SkaleDKG skaleDKG = SkaleDKG(contractManager.getContract("SkaleDKG"));
        require(skaleDKG.isNodeBroadcasted(schainId, fromNodeIndex), "Node has not broadcasted");
        if (skaleDKG.isNodeBroadcasted(schainId, toNodeIndex)) {
            _handleComplaintWhenBroadcasted(
                schainId,
                fromNodeIndex,
                toNodeIndex,
                contractManager,
                complaints,
                startAlrightTimestamp
            );
        } else {
            // not broadcasted in 30 min
            _handleComplaintWhenNotBroadcasted(schainId, toNodeIndex, contractManager, channels);
        }
        skaleDKG.setBadNode(schainId, toNodeIndex);
    }

    function complaintBadData(
        bytes32 schainId,
        uint fromNodeIndex,
        uint toNodeIndex,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints
    )
        external
    { 
        SkaleDKG skaleDKG = SkaleDKG(contractManager.getContract("SkaleDKG"));
        require(skaleDKG.isNodeBroadcasted(schainId, fromNodeIndex), "Node has not broadcasted");
        require(skaleDKG.isNodeBroadcasted(schainId, toNodeIndex), "Accused node has not broadcasted");
        require(!skaleDKG.isAllDataReceived(schainId, fromNodeIndex), "Node has already sent alright");
        if (complaints[schainId].nodeToComplaint == uint(-1)) {
            complaints[schainId].nodeToComplaint = toNodeIndex;
            complaints[schainId].fromNodeToComplaint = fromNodeIndex;
            complaints[schainId].startComplaintBlockTimestamp = block.timestamp;
            emit ComplaintSent(schainId, fromNodeIndex, toNodeIndex);
        } else {
            emit ComplaintError("First complaint has already been processed");
        }
    }

    function _handleComplaintWhenBroadcasted(
        bytes32 schainId,
        uint fromNodeIndex,
        uint toNodeIndex,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints,
        mapping(bytes32 => uint) storage startAlrightTimestamp
    )
        private
    {
        SkaleDKG skaleDKG = SkaleDKG(contractManager.getContract("SkaleDKG"));
        // missing alright
        if (complaints[schainId].nodeToComplaint == uint(-1)) {
            if (
                skaleDKG.isEveryoneBroadcasted(schainId) &&
                !skaleDKG.isAllDataReceived(schainId, toNodeIndex) &&
                startAlrightTimestamp[schainId].add(_getComplaintTimelimit(contractManager)) <= block.timestamp
            ) {
                // missing alright
                skaleDKG.finalizeSlashing(schainId, toNodeIndex);
                return;
            } else if (!skaleDKG.isAllDataReceived(schainId, fromNodeIndex)) {
                // incorrect data
                skaleDKG.finalizeSlashing(schainId, fromNodeIndex);
                return;
            }
            emit ComplaintError("Has already sent alright");
            return;
        } else if (complaints[schainId].nodeToComplaint == toNodeIndex) {
            // 30 min after incorrect data complaint
            if (complaints[schainId].startComplaintBlockTimestamp.add(
                _getComplaintTimelimit(contractManager)
            ) <= block.timestamp) {
                skaleDKG.finalizeSlashing(schainId, complaints[schainId].nodeToComplaint);
                return;
            }
            emit ComplaintError("The same complaint rejected");
            return;
        }
        emit ComplaintError("One complaint is already sent");
    }


    function _handleComplaintWhenNotBroadcasted(
        bytes32 schainId,
        uint toNodeIndex,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.Channel) storage channels
    ) 
        private
    {
        if (channels[schainId].startedBlockTimestamp.add(_getComplaintTimelimit(contractManager)) <= block.timestamp) {
            SkaleDKG(contractManager.getContract("SkaleDKG")).finalizeSlashing(schainId, toNodeIndex);
            return;
        }
        emit ComplaintError("Complaint sent too early");
    }

    function _getComplaintTimelimit(ContractManager contractManager) private view returns (uint) {
        return ConstantsHolder(contractManager.getConstantsHolder()).complaintTimelimit();
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDkgPreResponse.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../SkaleDKG.sol";
import "../Wallets.sol";
import "../utils/FieldOperations.sol";

/**
 * @title SkaleDkgPreResponse
 * @dev Contains functions to manage distributed key generation per
 * Joint-Feldman protocol.
 */
library SkaleDkgPreResponse {
    using SafeMath for uint;
    using G2Operations for G2Operations.G2Point;

    function preResponse(
        bytes32 schainId,
        uint fromNodeIndex,
        G2Operations.G2Point[] memory verificationVector,
        G2Operations.G2Point[] memory verificationVectorMult,
        SkaleDKG.KeyShare[] memory secretKeyContribution,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints,
        mapping(bytes32 => mapping(uint => bytes32)) storage hashedData
    )
        external
    {
        SkaleDKG skaleDKG = SkaleDKG(contractManager.getContract("SkaleDKG"));
        uint index = _preResponseCheck(
            schainId,
            fromNodeIndex,
            verificationVector,
            verificationVectorMult,
            secretKeyContribution,
            skaleDKG,
            complaints,
            hashedData
        );
        _processPreResponse(secretKeyContribution[index].share, schainId, verificationVectorMult, complaints);
    }

    function _preResponseCheck(
        bytes32 schainId,
        uint fromNodeIndex,
        G2Operations.G2Point[] memory verificationVector,
        G2Operations.G2Point[] memory verificationVectorMult,
        SkaleDKG.KeyShare[] memory secretKeyContribution,
        SkaleDKG skaleDKG,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints,
        mapping(bytes32 => mapping(uint => bytes32)) storage hashedData
    )
        private
        view
        returns (uint index)
    {
        (uint indexOnSchain, ) = skaleDKG.checkAndReturnIndexInGroup(schainId, fromNodeIndex, true);
        require(complaints[schainId].nodeToComplaint == fromNodeIndex, "Not this Node");
        require(!complaints[schainId].isResponse, "Already submitted pre response data");
        require(
            hashedData[schainId][indexOnSchain] == skaleDKG.hashData(secretKeyContribution, verificationVector),
            "Broadcasted Data is not correct"
        );
        require(
            verificationVector.length == verificationVectorMult.length,
            "Incorrect length of multiplied verification vector"
        );
        (index, ) = skaleDKG.checkAndReturnIndexInGroup(schainId, complaints[schainId].fromNodeToComplaint, true);
        require(
            _checkCorrectVectorMultiplication(index, verificationVector, verificationVectorMult),
            "Multiplied verification vector is incorrect"
        ); 
    }

    function _processPreResponse(
        bytes32 share,
        bytes32 schainId,
        G2Operations.G2Point[] memory verificationVectorMult,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints
    )
        private
    {
        complaints[schainId].keyShare = share;
        complaints[schainId].sumOfVerVec = _calculateSum(verificationVectorMult);
        complaints[schainId].isResponse = true;
    }

    function _calculateSum(G2Operations.G2Point[] memory verificationVectorMult)
        private
        view
        returns (G2Operations.G2Point memory)
    {
        G2Operations.G2Point memory value = G2Operations.getG2Zero();
        for (uint i = 0; i < verificationVectorMult.length; i++) {
            value = value.addG2(verificationVectorMult[i]);
        }
        return value;
    }

    function _checkCorrectVectorMultiplication(
        uint indexOnSchain,
        G2Operations.G2Point[] memory verificationVector,
        G2Operations.G2Point[] memory verificationVectorMult
    )
        private
        view
        returns (bool)
    {
        Fp2Operations.Fp2Point memory value = G1Operations.getG1Generator();
        Fp2Operations.Fp2Point memory tmp = G1Operations.getG1Generator();
        for (uint i = 0; i < verificationVector.length; i++) {
            (tmp.a, tmp.b) = Precompiled.bn256ScalarMul(value.a, value.b, indexOnSchain.add(1) ** i);
            if (!_checkPairing(tmp, verificationVector[i], verificationVectorMult[i])) {
                return false;
            }
        }
        return true;
    }

    function _checkPairing(
        Fp2Operations.Fp2Point memory g1Mul,
        G2Operations.G2Point memory verificationVector,
        G2Operations.G2Point memory verificationVectorMult
    )
        private
        view
        returns (bool)
    {
        require(G1Operations.checkRange(g1Mul), "g1Mul is not valid");
        g1Mul.b = G1Operations.negate(g1Mul.b);
        Fp2Operations.Fp2Point memory one = G1Operations.getG1Generator();
        return Precompiled.bn256Pairing(
            one.a, one.b,
            verificationVectorMult.x.b, verificationVectorMult.x.a,
            verificationVectorMult.y.b, verificationVectorMult.y.a,
            g1Mul.a, g1Mul.b,
            verificationVector.x.b, verificationVector.x.a,
            verificationVector.y.b, verificationVector.y.a
        );
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDkgResponse.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../SkaleDKG.sol";
import "../Wallets.sol";
import "../Decryption.sol";
import "../Nodes.sol";
import "../thirdparty/ECDH.sol";
import "../utils/FieldOperations.sol";

/**
 * @title SkaleDkgResponse
 * @dev Contains functions to manage distributed key generation per
 * Joint-Feldman protocol.
 */
library SkaleDkgResponse {
    using G2Operations for G2Operations.G2Point;

    function response(
        bytes32 schainId,
        uint fromNodeIndex,
        uint secretNumber,
        G2Operations.G2Point memory multipliedShare,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.Channel) storage channels,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints
    )
        external
    {
        uint index = SchainsInternal(contractManager.getContract("SchainsInternal"))
            .getNodeIndexInGroup(schainId, fromNodeIndex);
        require(index < channels[schainId].n, "Node is not in this group");
        require(complaints[schainId].nodeToComplaint == fromNodeIndex, "Not this Node");
        require(complaints[schainId].isResponse, "Have not submitted pre-response data");
        uint badNode = _verifyDataAndSlash(
            schainId,
            secretNumber,
            multipliedShare,
            contractManager,
            complaints
         );
        SkaleDKG(contractManager.getContract("SkaleDKG")).setBadNode(schainId, badNode);
    }

    function _verifyDataAndSlash(
        bytes32 schainId,
        uint secretNumber,
        G2Operations.G2Point memory multipliedShare,
        ContractManager contractManager,
        mapping(bytes32 => SkaleDKG.ComplaintData) storage complaints
    )
        private
        returns (uint badNode)
    {
        bytes32[2] memory publicKey = Nodes(contractManager.getContract("Nodes")).getNodePublicKey(
            complaints[schainId].fromNodeToComplaint
        );
        uint256 pkX = uint(publicKey[0]);

        (pkX, ) = ECDH(contractManager.getContract("ECDH")).deriveKey(secretNumber, pkX, uint(publicKey[1]));
        bytes32 key = bytes32(pkX);

        // Decrypt secret key contribution
        uint secret = Decryption(contractManager.getContract("Decryption")).decrypt(
            complaints[schainId].keyShare,
            sha256(abi.encodePacked(key))
        );

        badNode = (
            _checkCorrectMultipliedShare(multipliedShare, secret) &&
            multipliedShare.isEqual(complaints[schainId].sumOfVerVec) ?
            complaints[schainId].fromNodeToComplaint :
            complaints[schainId].nodeToComplaint
        );
        SkaleDKG(contractManager.getContract("SkaleDKG")).finalizeSlashing(schainId, badNode);
    }

    function _checkCorrectMultipliedShare(
        G2Operations.G2Point memory multipliedShare,
        uint secret
    )
        private
        view
        returns (bool)
    {
        if (!multipliedShare.isG2()) {
            return false;
        }
        G2Operations.G2Point memory tmp = multipliedShare;
        Fp2Operations.Fp2Point memory g1 = G1Operations.getG1Generator();
        Fp2Operations.Fp2Point memory share = Fp2Operations.Fp2Point({
            a: 0,
            b: 0
        });
        (share.a, share.b) = Precompiled.bn256ScalarMul(g1.a, g1.b, secret);
        require(G1Operations.checkRange(share), "share is not valid");
        share.b = G1Operations.negate(share.b);

        require(G1Operations.isG1(share), "mulShare not in G1");

        G2Operations.G2Point memory g2 = G2Operations.getG2Generator();

        return Precompiled.bn256Pairing(
            share.a, share.b,
            g2.x.b, g2.x.a, g2.y.b, g2.y.a,
            g1.a, g1.b,
            tmp.x.b, tmp.x.a, tmp.y.b, tmp.y.a);
    }

}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleVerifier.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "./Permissions.sol";
import "./SchainsInternal.sol";
import "./utils/Precompiled.sol";
import "./utils/FieldOperations.sol";

/**
 * @title SkaleVerifier
 * @dev Contains verify function to perform BLS signature verification.
 */
contract SkaleVerifier is Permissions {  
    using Fp2Operations for Fp2Operations.Fp2Point;


    /**
    * @dev Verifies a BLS signature.
    * 
    * Requirements:
    * 
    * - Signature is in G1.
    * - Hash is in G1.
    * - G2.one in G2.
    * - Public Key in G2.
    */
    function verify(
        Fp2Operations.Fp2Point calldata signature,
        bytes32 hash,
        uint counter,
        uint hashA,
        uint hashB,
        G2Operations.G2Point calldata publicKey
    )
        external
        view
        returns (bool)
    {
        require(G1Operations.checkRange(signature), "Signature is not valid");
        if (!_checkHashToGroupWithHelper(
            hash,
            counter,
            hashA,
            hashB
            )
        )
        {
            return false;
        }

        uint newSignB = G1Operations.negate(signature.b);
        require(G1Operations.isG1Point(signature.a, newSignB), "Sign not in G1");
        require(G1Operations.isG1Point(hashA, hashB), "Hash not in G1");

        G2Operations.G2Point memory g2 = G2Operations.getG2Generator();
        require(
            G2Operations.isG2(publicKey),
            "Public Key not in G2"
        );

        return Precompiled.bn256Pairing(
            signature.a, newSignB,
            g2.x.b, g2.x.a, g2.y.b, g2.y.a,
            hashA, hashB,
            publicKey.x.b, publicKey.x.a, publicKey.y.b, publicKey.y.a
        );
    }

    function initialize(address newContractsAddress) public override initializer {
        Permissions.initialize(newContractsAddress);
    }

    function _checkHashToGroupWithHelper(
        bytes32 hash,
        uint counter,
        uint hashA,
        uint hashB
    )
        private
        pure
        returns (bool)
    {
        if (counter > 100) {
            return false;
        }
        uint xCoord = uint(hash) % Fp2Operations.P;
        xCoord = (xCoord.add(counter)) % Fp2Operations.P;

        uint ySquared = addmod(
            mulmod(mulmod(xCoord, xCoord, Fp2Operations.P), xCoord, Fp2Operations.P),
            3,
            Fp2Operations.P
        );
        if (hashB < Fp2Operations.P.div(2) || mulmod(hashB, hashB, Fp2Operations.P) != ySquared || xCoord != hashA) {
            return false;
        }

        return true;
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Decryption.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

/**
 * @title Decryption
 * @dev This contract performs encryption and decryption functions.
 * Decrypt is used by SkaleDKG contract to decrypt secret key contribution to
 * validate complaints during the DKG procedure.
 */
contract Decryption {

    /**
     * @dev Returns an encrypted text given a secret and a key.
     */
    function encrypt(uint256 secretNumber, bytes32 key) external pure returns (bytes32 ciphertext) {
        return bytes32(secretNumber) ^ key;
    }

    /**
     * @dev Returns a secret given an encrypted text and a key.
     */
    function decrypt(bytes32 ciphertext, bytes32 key) external pure returns (uint256 secretNumber) {
        return uint256(ciphertext ^ key);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    PartialDifferencesTester.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

import "../delegation/PartialDifferences.sol";


contract PartialDifferencesTester {
    using PartialDifferences for PartialDifferences.Sequence;
    using PartialDifferences for PartialDifferences.Value;
    using SafeMath for uint;

    PartialDifferences.Sequence[] private _sequences;
    // PartialDifferences.Value[] private _values;

    function createSequence() external {
        _sequences.push(PartialDifferences.Sequence({firstUnprocessedMonth: 0, lastChangedMonth: 0}));
    }

    function addToSequence(uint sequence, uint diff, uint month) external {
        require(sequence < _sequences.length, "Sequence does not exist");
        _sequences[sequence].addToSequence(diff, month);
    }

    function subtractFromSequence(uint sequence, uint diff, uint month) external {
        require(sequence < _sequences.length, "Sequence does not exist");
        _sequences[sequence].subtractFromSequence(diff, month);
    }

    function getAndUpdateSequenceItem(uint sequence, uint month) external returns (uint) {
        require(sequence < _sequences.length, "Sequence does not exist");
        return _sequences[sequence].getAndUpdateValueInSequence(month);
    }

    function reduceSequence(
        uint sequence,
        uint a,
        uint b,
        uint month) external
    {
        require(sequence < _sequences.length, "Sequence does not exist");
        FractionUtils.Fraction memory reducingCoefficient = FractionUtils.createFraction(a, b);
        return _sequences[sequence].reduceSequence(reducingCoefficient, month);
    }

    function latestSequence() external view returns (uint id) {
        require(_sequences.length > 0, "There are no _sequences");
        return _sequences.length.sub(1);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    ReentrancyTester.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Sender.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777.sol";

import "../Permissions.sol";
import "../delegation/DelegationController.sol";


contract ReentrancyTester is Permissions, IERC777Recipient, IERC777Sender {

    IERC1820Registry private _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bool private _reentrancyCheck = false;
    bool private _burningAttack = false;
    uint private _amount = 0;

    constructor (address contractManagerAddress) public {
        Permissions.initialize(contractManagerAddress);
        _erc1820.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
        _erc1820.setInterfaceImplementer(address(this), keccak256("ERC777TokensSender"), address(this));
    }

    function tokensReceived(
        address /* operator */,
        address /* from */,
        address /* to */,
        uint256 amount,
        bytes calldata /* userData */,
        bytes calldata /* operatorData */
    )
        external override
    {
        if (_reentrancyCheck) {
            IERC20 skaleToken = IERC20(contractManager.getContract("SkaleToken"));

            require(
                skaleToken.transfer(contractManager.getContract("SkaleToken"), amount),
                "Transfer is not successful");
        }
    }

    function tokensToSend(
        address, // operator
        address, // from
        address, // to
        uint256, // amount
        bytes calldata, // userData
        bytes calldata // operatorData
    ) external override
    {
        if (_burningAttack) {
            DelegationController delegationController = DelegationController(
                contractManager.getContract("DelegationController"));
            delegationController.delegate(
                1,
                _amount,
                2,
                "D2 is even");
        }
    }

    function prepareToReentracyCheck() external {
        _reentrancyCheck = true;
    }

    function prepareToBurningAttack() external {
        _burningAttack = true;
    }

    function burningAttack() external {
        IERC777 skaleToken = IERC777(contractManager.getContract("SkaleToken"));

        _amount = skaleToken.balanceOf(address(this));

        skaleToken.burn(_amount, "");
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleManager.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";

import "./delegation/Distributor.sol";
import "./delegation/ValidatorService.sol";
import "./interfaces/IMintableToken.sol";
import "./BountyV2.sol";
import "./ConstantsHolder.sol";
import "./NodeRotation.sol";
import "./Permissions.sol";
import "./Schains.sol";
import "./Wallets.sol";

/**
 * @title SkaleManager
 * @dev Contract contains functions for node registration and exit, bounty
 * management, and monitoring verdicts.
 */
contract SkaleManager is IERC777Recipient, Permissions {
    IERC1820Registry private _erc1820;

    bytes32 constant private _TOKENS_RECIPIENT_INTERFACE_HASH =
        0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b;

    bytes32 constant public ADMIN_ROLE = keccak256("ADMIN_ROLE");

    string public version;

    /**
     * @dev Emitted when bounty is received.
     */
    event BountyReceived(
        uint indexed nodeIndex,
        address owner,
        uint averageDowntime,
        uint averageLatency,
        uint bounty,
        uint previousBlockEvent,
        uint time,
        uint gasSpend
    );

    function tokensReceived(
        address, // operator
        address from,
        address to,
        uint256 value,
        bytes calldata userData,
        bytes calldata // operator data
    )
        external override
        allow("SkaleToken")
    {
        require(to == address(this), "Receiver is incorrect");
        if (userData.length > 0) {
            Schains schains = Schains(
                contractManager.getContract("Schains"));
            schains.addSchain(from, value, userData);
        }
    }

    function createNode(
        uint16 port,
        uint16 nonce,
        bytes4 ip,
        bytes4 publicIp,
        bytes32[2] calldata publicKey,
        string calldata name,
        string calldata domainName
    )
        external
    {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        // validators checks inside checkPossibilityCreatingNode
        nodes.checkPossibilityCreatingNode(msg.sender);

        Nodes.NodeCreationParams memory params = Nodes.NodeCreationParams({
            name: name,
            ip: ip,
            publicIp: publicIp,
            port: port,
            publicKey: publicKey,
            nonce: nonce,
            domainName: domainName
        });
        nodes.createNode(msg.sender, params);
    }

    function nodeExit(uint nodeIndex) external {
        uint gasTotal = gasleft();
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        NodeRotation nodeRotation = NodeRotation(contractManager.getContract("NodeRotation"));
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        uint validatorId = nodes.getValidatorId(nodeIndex);
        bool permitted = (_isOwner() || nodes.isNodeExist(msg.sender, nodeIndex));
        if (!permitted && validatorService.validatorAddressExists(msg.sender)) {
            permitted = validatorService.getValidatorId(msg.sender) == validatorId;
        }
        require(permitted, "Sender is not permitted to call this function");
        nodeRotation.freezeSchains(nodeIndex);
        if (nodes.isNodeActive(nodeIndex)) {
            require(nodes.initExit(nodeIndex), "Initialization of node exit is failed");
        }
        require(nodes.isNodeLeaving(nodeIndex), "Node should be Leaving");
        (bool completed, bool isSchains) = nodeRotation.exitFromSchain(nodeIndex);
        if (completed) {
            SchainsInternal(
                contractManager.getContract("SchainsInternal")
            ).removeNodeFromAllExceptionSchains(nodeIndex);
            require(nodes.completeExit(nodeIndex), "Finishing of node exit is failed");
            nodes.changeNodeFinishTime(
                nodeIndex,
                now.add(
                    isSchains ?
                    ConstantsHolder(contractManager.getContract("ConstantsHolder")).rotationDelay() :
                    0
                )
            );
            nodes.deleteNodeForValidator(validatorId, nodeIndex);
        }
        _refundGasByValidator(validatorId, msg.sender, gasTotal - gasleft());
    }

    function deleteSchain(string calldata name) external {
        Schains schains = Schains(contractManager.getContract("Schains"));
        // schain owner checks inside deleteSchain
        schains.deleteSchain(msg.sender, name);
    }

    function deleteSchainByRoot(string calldata name) external onlyAdmin {
        Schains schains = Schains(contractManager.getContract("Schains"));
        schains.deleteSchainByRoot(name);
    }

    function getBounty(uint nodeIndex) external {
        uint gasTotal = gasleft();
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        require(nodes.isNodeExist(msg.sender, nodeIndex), "Node does not exist for Message sender");
        require(nodes.isTimeForReward(nodeIndex), "Not time for bounty");
        require(!nodes.isNodeLeft(nodeIndex), "The node must not be in Left state");
        BountyV2 bountyContract = BountyV2(contractManager.getContract("Bounty"));

        uint bounty = bountyContract.calculateBounty(nodeIndex);

        nodes.changeNodeLastRewardDate(nodeIndex);
        uint validatorId = nodes.getValidatorId(nodeIndex);
        if (bounty > 0) {
            _payBounty(bounty, validatorId);
        }

        emit BountyReceived(
            nodeIndex,
            msg.sender,
            0,
            0,
            bounty,
            uint(-1),
            block.timestamp,
            gasleft());
        
        _refundGasByValidator(validatorId, msg.sender, gasTotal - gasleft());
    }

    function setVersion(string calldata newVersion) external onlyOwner {
        version = newVersion;
    }

    function initialize(address newContractsAddress) public override initializer {
        Permissions.initialize(newContractsAddress);
        _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
        _erc1820.setInterfaceImplementer(address(this), _TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    function _payBounty(uint bounty, uint validatorId) private returns (bool) {        
        IERC777 skaleToken = IERC777(contractManager.getContract("SkaleToken"));
        Distributor distributor = Distributor(contractManager.getContract("Distributor"));
        
        require(
            IMintableToken(address(skaleToken)).mint(address(distributor), bounty, abi.encode(validatorId), ""),
            "Token was not minted"
        );
    }

    function _refundGasByValidator(uint validatorId, address payable spender, uint spentGas) private {
        uint gasCostOfRefundGasByValidator = 29000;
        Wallets(payable(contractManager.getContract("Wallets")))
        .refundGasByValidator(validatorId, spender, spentGas + gasCostOfRefundGasByValidator);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Distributor.sol - SKALE Manager
    Copyright (C) 2019-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

import "../Permissions.sol";
import "../ConstantsHolder.sol";
import "../utils/MathUtils.sol";

import "./ValidatorService.sol";
import "./DelegationController.sol";
import "./DelegationPeriodManager.sol";
import "./TimeHelpers.sol";

/**
 * @title Distributor
 * @dev This contract handles all distribution functions of bounty and fee
 * payments.
 */
contract Distributor is Permissions, IERC777Recipient {
    using MathUtils for uint;

    /**
     * @dev Emitted when bounty is withdrawn.
     */
    event WithdrawBounty(
        address holder,
        uint validatorId,
        address destination,
        uint amount
    );

    /**
     * @dev Emitted when a validator fee is withdrawn.
     */
    event WithdrawFee(
        uint validatorId,
        address destination,
        uint amount
    );

    /**
     * @dev Emitted when bounty is distributed.
     */
    event BountyWasPaid(
        uint validatorId,
        uint amount
    );

    IERC1820Registry private _erc1820;

    // validatorId =>        month => token
    mapping (uint => mapping (uint => uint)) private _bountyPaid;
    // validatorId =>        month => token
    mapping (uint => mapping (uint => uint)) private _feePaid;
    //        holder =>   validatorId => month
    mapping (address => mapping (uint => uint)) private _firstUnwithdrawnMonth;
    // validatorId => month
    mapping (uint => uint) private _firstUnwithdrawnMonthForValidator;

    /**
     * @dev Return and update the amount of earned bounty from a validator.
     */
    function getAndUpdateEarnedBountyAmount(uint validatorId) external returns (uint earned, uint endMonth) {
        return getAndUpdateEarnedBountyAmountOf(msg.sender, validatorId);
    }

    /**
     * @dev Allows msg.sender to withdraw earned bounty. Bounties are locked
     * until launchTimestamp and BOUNTY_LOCKUP_MONTHS have both passed.
     * 
     * Emits a {WithdrawBounty} event.
     * 
     * Requirements:
     * 
     * - Bounty must be unlocked.
     */
    function withdrawBounty(uint validatorId, address to) external {
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getContract("TimeHelpers"));
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getContract("ConstantsHolder"));

        require(now >= timeHelpers.addMonths(
                constantsHolder.launchTimestamp(),
                constantsHolder.BOUNTY_LOCKUP_MONTHS()
            ), "Bounty is locked");

        uint bounty;
        uint endMonth;
        (bounty, endMonth) = getAndUpdateEarnedBountyAmountOf(msg.sender, validatorId);

        _firstUnwithdrawnMonth[msg.sender][validatorId] = endMonth;

        IERC20 skaleToken = IERC20(contractManager.getContract("SkaleToken"));
        require(skaleToken.transfer(to, bounty), "Failed to transfer tokens");

        emit WithdrawBounty(
            msg.sender,
            validatorId,
            to,
            bounty
        );
    }

    /**
     * @dev Allows `msg.sender` to withdraw earned validator fees. Fees are 
     * locked until launchTimestamp and BOUNTY_LOCKUP_MONTHS both have passed.
     * 
     * Emits a {WithdrawFee} event.
     * 
     * Requirements:
     * 
     * - Fee must be unlocked.
     */
    function withdrawFee(address to) external {
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        IERC20 skaleToken = IERC20(contractManager.getContract("SkaleToken"));
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getContract("TimeHelpers"));
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getContract("ConstantsHolder"));

        require(now >= timeHelpers.addMonths(
                constantsHolder.launchTimestamp(),
                constantsHolder.BOUNTY_LOCKUP_MONTHS()
            ), "Fee is locked");
        // check Validator Exist inside getValidatorId
        uint validatorId = validatorService.getValidatorId(msg.sender);

        uint fee;
        uint endMonth;
        (fee, endMonth) = getEarnedFeeAmountOf(validatorId);

        _firstUnwithdrawnMonthForValidator[validatorId] = endMonth;

        require(skaleToken.transfer(to, fee), "Failed to transfer tokens");

        emit WithdrawFee(
            validatorId,
            to,
            fee
        );
    }

    function tokensReceived(
        address,
        address,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata
    )
        external override
        allow("SkaleToken")
    {
        require(to == address(this), "Receiver is incorrect");
        require(userData.length == 32, "Data length is incorrect");
        uint validatorId = abi.decode(userData, (uint));
        _distributeBounty(amount, validatorId);
    }

    /**
     * @dev Return the amount of earned validator fees of `msg.sender`.
     */
    function getEarnedFeeAmount() external view returns (uint earned, uint endMonth) {
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));
        return getEarnedFeeAmountOf(validatorService.getValidatorId(msg.sender));
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
        _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
        _erc1820.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
    }

    /**
     * @dev Return and update the amount of earned bounties.
     */
    function getAndUpdateEarnedBountyAmountOf(address wallet, uint validatorId)
        public returns (uint earned, uint endMonth)
    {
        DelegationController delegationController = DelegationController(
            contractManager.getContract("DelegationController"));
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getContract("TimeHelpers"));

        uint currentMonth = timeHelpers.getCurrentMonth();

        uint startMonth = _firstUnwithdrawnMonth[wallet][validatorId];
        if (startMonth == 0) {
            startMonth = delegationController.getFirstDelegationMonth(wallet, validatorId);
            if (startMonth == 0) {
                return (0, 0);
            }
        }

        earned = 0;
        endMonth = currentMonth;
        if (endMonth > startMonth.add(12)) {
            endMonth = startMonth.add(12);
        }
        for (uint i = startMonth; i < endMonth; ++i) {
            uint effectiveDelegatedToValidator =
                delegationController.getAndUpdateEffectiveDelegatedToValidator(validatorId, i);
            if (effectiveDelegatedToValidator.muchGreater(0)) {
                earned = earned.add(
                    _bountyPaid[validatorId][i].mul(
                        delegationController.getAndUpdateEffectiveDelegatedByHolderToValidator(wallet, validatorId, i))
                            .div(effectiveDelegatedToValidator)
                    );
            }
        }
    }

    /**
     * @dev Return the amount of earned fees by validator ID.
     */
    function getEarnedFeeAmountOf(uint validatorId) public view returns (uint earned, uint endMonth) {
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getContract("TimeHelpers"));

        uint currentMonth = timeHelpers.getCurrentMonth();

        uint startMonth = _firstUnwithdrawnMonthForValidator[validatorId];
        if (startMonth == 0) {
            return (0, 0);
        }

        earned = 0;
        endMonth = currentMonth;
        if (endMonth > startMonth.add(12)) {
            endMonth = startMonth.add(12);
        }
        for (uint i = startMonth; i < endMonth; ++i) {
            earned = earned.add(_feePaid[validatorId][i]);
        }
    }

    // private

    /**
     * @dev Distributes bounties to delegators.
     * 
     * Emits a {BountyWasPaid} event.
     */
    function _distributeBounty(uint amount, uint validatorId) private {
        TimeHelpers timeHelpers = TimeHelpers(contractManager.getContract("TimeHelpers"));
        ValidatorService validatorService = ValidatorService(contractManager.getContract("ValidatorService"));

        uint currentMonth = timeHelpers.getCurrentMonth();
        uint feeRate = validatorService.getValidator(validatorId).feeRate;

        uint fee = amount.mul(feeRate).div(1000);
        uint bounty = amount.sub(fee);
        _bountyPaid[validatorId][currentMonth] = _bountyPaid[validatorId][currentMonth].add(bounty);
        _feePaid[validatorId][currentMonth] = _feePaid[validatorId][currentMonth].add(fee);

        if (_firstUnwithdrawnMonthForValidator[validatorId] == 0) {
            _firstUnwithdrawnMonthForValidator[validatorId] = currentMonth;
        }

        emit BountyWasPaid(validatorId, amount);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDKGTester.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../SkaleDKG.sol";

contract SkaleDKGTester is SkaleDKG {
    function setSuccessfulDKGPublic(bytes32 schainId) external {
        lastSuccesfulDKG[schainId] = now;
        channels[schainId].active = false;
        KeyStorage(contractManager.getContract("KeyStorage")).finalizePublicKey(schainId);
        emit SuccessfulDKG(schainId);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    NodesTester.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/
pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../Nodes.sol";


contract NodesTester is Nodes {
    
    function removeNodeFromSpaceToNodes(uint nodeIndex) external {
        uint8 space = spaceOfNodes[nodeIndex].freeSpace;
        _removeNodeFromSpaceToNodes(nodeIndex, space);
    }

    function removeNodesFromPlace(uint place, uint nodesAmount) external {
        SegmentTree.Tree storage tree = _getNodesAmountBySpace();
        tree.removeFromPlace(place, nodesAmount);
    }

    function amountOfNodesFromPlaceInTree(uint place) external view returns (uint) {
        SegmentTree.Tree storage tree = _getNodesAmountBySpace();
        return tree.sumFromPlaceToLast(place);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    Pricing.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin
    @author Vadim Yavorsky

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "./Permissions.sol";
import "./SchainsInternal.sol";
import "./Nodes.sol";

/**
 * @title Pricing
 * @dev Contains pricing operations for SKALE network.
 */
contract Pricing is Permissions {

    uint public constant INITIAL_PRICE = 5 * 10**6;

    uint public price;
    uint public totalNodes;
    uint public lastUpdated;

    function initNodes() external {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        totalNodes = nodes.getNumberOnlineNodes();
    }

    /**
     * @dev Adjust the schain price based on network capacity and demand.
     * 
     * Requirements:
     * 
     * - Cooldown time has exceeded.
     */
    function adjustPrice() external {
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getContract("ConstantsHolder"));
        require(now > lastUpdated.add(constantsHolder.COOLDOWN_TIME()), "It's not a time to update a price");
        checkAllNodes();
        uint load = _getTotalLoad();
        uint capacity = _getTotalCapacity();

        bool networkIsOverloaded = load.mul(100) > constantsHolder.OPTIMAL_LOAD_PERCENTAGE().mul(capacity);
        uint loadDiff;
        if (networkIsOverloaded) {
            loadDiff = load.mul(100).sub(constantsHolder.OPTIMAL_LOAD_PERCENTAGE().mul(capacity));
        } else {
            loadDiff = constantsHolder.OPTIMAL_LOAD_PERCENTAGE().mul(capacity).sub(load.mul(100));
        }

        uint priceChangeSpeedMultipliedByCapacityAndMinPrice =
            constantsHolder.ADJUSTMENT_SPEED().mul(loadDiff).mul(price);
        
        uint timeSkipped = now.sub(lastUpdated);
        
        uint priceChange = priceChangeSpeedMultipliedByCapacityAndMinPrice
            .mul(timeSkipped)
            .div(constantsHolder.COOLDOWN_TIME())
            .div(capacity)
            .div(constantsHolder.MIN_PRICE());

        if (networkIsOverloaded) {
            assert(priceChange > 0);
            price = price.add(priceChange);
        } else {
            if (priceChange > price) {
                price = constantsHolder.MIN_PRICE();
            } else {
                price = price.sub(priceChange);
                if (price < constantsHolder.MIN_PRICE()) {
                    price = constantsHolder.MIN_PRICE();
                }
            }
        }
        lastUpdated = now;
    }

    /**
     * @dev Returns the total load percentage.
     */
    function getTotalLoadPercentage() external view returns (uint) {
        return _getTotalLoad().mul(100).div(_getTotalCapacity());
    }

    function initialize(address newContractsAddress) public override initializer {
        Permissions.initialize(newContractsAddress);
        lastUpdated = now;
        price = INITIAL_PRICE;
    }

    function checkAllNodes() public {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        uint numberOfActiveNodes = nodes.getNumberOnlineNodes();

        require(totalNodes != numberOfActiveNodes, "No changes to node supply");
        totalNodes = numberOfActiveNodes;
    }

    function _getTotalLoad() private view returns (uint) {
        SchainsInternal schainsInternal = SchainsInternal(contractManager.getContract("SchainsInternal"));

        uint load = 0;
        uint numberOfSchains = schainsInternal.numberOfSchains();
        for (uint i = 0; i < numberOfSchains; i++) {
            bytes32 schain = schainsInternal.schainsAtSystem(i);
            uint numberOfNodesInSchain = schainsInternal.getNumberOfNodesInGroup(schain);
            uint part = schainsInternal.getSchainsPartOfNode(schain);
            load = load.add(
                numberOfNodesInSchain.mul(part)
            );
        }
        return load;
    }

    function _getTotalCapacity() private view returns (uint) {
        Nodes nodes = Nodes(contractManager.getContract("Nodes"));
        ConstantsHolder constantsHolder = ConstantsHolder(contractManager.getContract("ConstantsHolder"));

        return nodes.getNumberOnlineNodes().mul(constantsHolder.TOTAL_SPACE_ON_NODE());
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SchainsInternalMock.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../SchainsInternal.sol";

contract SchainsInternalMock is SchainsInternal {

    function removePlaceOfSchainOnNode(bytes32 schainHash, uint nodeIndex) external {
        delete placeOfSchainOnNode[schainHash][nodeIndex];
    }

    function removeNodeToLocked(uint nodeIndex) external {
        mapping(uint => bytes32[]) storage nodeToLocked = _getNodeToLockedSchains();
        delete nodeToLocked[nodeIndex];
    }

    function removeSchainToExceptionNode(bytes32 schainHash) external {
        mapping(bytes32 => uint[]) storage schainToException = _getSchainToExceptionNodes();
        delete schainToException[schainHash];
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    LockerMock.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "../interfaces/delegation/ILocker.sol";

contract LockerMock is ILocker {
    function getAndUpdateLockedAmount(address) external override returns (uint) {
        return 13;
    }
    
    function getAndUpdateForbiddenForDelegationAmount(address) external override returns (uint) {
        return 13;
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    MathUtilsTester.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;

import "../utils/MathUtils.sol";


contract MathUtilsTester {
    using MathUtils for uint;

    function boundedSub(uint256 a, uint256 b) external returns (uint256) {
        return a.boundedSub(b);
    }

    function boundedSubWithoutEvent(uint256 a, uint256 b) external pure returns (uint256) {
        return a.boundedSubWithoutEvent(b);
    }

    function muchGreater(uint256 a, uint256 b) external pure returns (bool) {
        return a.muchGreater(b);
    }

    function approximatelyEqual(uint256 a, uint256 b) external pure returns (bool) {
        return a.approximatelyEqual(b);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

/*
    SegmentTreeTester.sol - SKALE Manager
    Copyright (C) 2021-Present SKALE Labs
    @author Artem Payvin
    @author Dmytro Stebaiev

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import "../utils/SegmentTree.sol";


contract SegmentTreeTester {

    using SegmentTree for SegmentTree.Tree;

    SegmentTree.Tree private _tree;

    uint[129] private _places;

    function initTree() external {
        _tree.create(128);
        for (uint8 i = 1; i <= 128; i++) {
            if (_places[i] > 0)
                _tree.addToPlace(i, _places[i]);
        }
    }

    function addElemInPlaces(uint place, uint elem) external {
        _places[place] = elem;
    }

    function addToLast(uint elem) external {
        _tree.addToPlace(_tree.getSize(), elem);
    }

    function addToPlace(uint place, uint elem) external {
        _tree.addToPlace(place, elem);
    }

    function removeFromPlace(uint place, uint elem) external {
        _tree.removeFromPlace(place, elem);
    }

    function moveFromPlaceToPlace(uint fromPlace, uint toPlace, uint elem) external {
        _tree.moveFromPlaceToPlace(fromPlace, toPlace, elem);
    }

    function sumFromPlaceToLast(uint place) external view returns (uint) {
        return _tree.sumFromPlaceToLast(place);
    }

    function getRandomElem(uint place) external view returns (uint) {
        Random.RandomGenerator memory randomGenerator = Random.createFromEntropy(
            abi.encodePacked(uint(blockhash(block.number - 1)), place)
        );
        return _tree.getRandomNonZeroElementFromPlaceToLast(place, randomGenerator);
    }

    function getElem(uint index) external view returns (uint) {
        require(index < _tree.tree.length, "Incorrect index");
        return _tree.tree[index];
    }

    function getSize() external view returns (uint) {
        return _tree.getSize();
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
  "libraries": {
    "contracts/utils/SegmentTree.sol": {
      "SegmentTree": "0xde5e12b55807a22763cfaac95d1ced5c93f3dc57"
    }
  }
}