// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IContractsRegistry.sol";
import "./interfaces/helpers/IPriceFeed.sol";
import "./interfaces/IClaimVoting.sol";
import "./interfaces/IPolicyBookRegistry.sol";
import "./interfaces/IReputationSystem.sol";
import "./interfaces/IReinsurancePool.sol";
import "./interfaces/IPolicyBook.sol";

import "./interfaces/tokens/IVBMI.sol";

import "./abstract/AbstractDependant.sol";

import "./Globals.sol";

contract ClaimVoting is IClaimVoting, Initializable, AbstractDependant {
    using SafeMath for uint256;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    IPriceFeed public priceFeed;

    IERC20 public bmiToken;
    IERC20 public daiToken;
    IReinsurancePool public reinsurancePool;
    IVBMI public vBMI;
    IClaimingRegistry public claimingRegistry;
    IPolicyBookRegistry public policyBookRegistry;
    IReputationSystem public reputationSystem;

    uint256 public constant PERCENTAGE_50 = 50 * PRECISION;

    uint256 public constant APPROVAL_PERCENTAGE = 66 * PRECISION;
    uint256 public constant PENALTY_THRESHOLD = 11 * PRECISION;
    uint256 public constant QUORUM = 10 * PRECISION;
    uint256 public constant CALCULATION_REWARD_PER_DAY = PRECISION;

    // claim index -> info
    mapping(uint256 => VotingResult) internal _votings;

    // voter -> claim indexes
    mapping(address => EnumerableSet.UintSet) internal _myNotCalculatedVotes;

    // voter -> voting indexes
    mapping(address => EnumerableSet.UintSet) internal _myVotes;

    // voter -> claim index -> vote index
    mapping(address => mapping(uint256 => uint256)) internal _allVotesToIndex;

    // vote index -> voting instance
    mapping(uint256 => VotingInst) internal _allVotesByIndexInst;

    EnumerableSet.UintSet internal _allVotesIndexes;

    uint256 private _voteIndex;

    event AnonymouslyVoted(uint256 claimIndex);
    event VoteExposed(uint256 claimIndex, address voter, uint256 suggestedClaimAmount);
    event VoteCalculated(uint256 claimIndex, address voter, VoteStatus status);
    event RewardsForVoteCalculationSent(address voter, uint256 bmiAmount);
    event RewardsForClaimCalculationSent(address calculator, uint256 bmiAmount);
    event ClaimCalculated(uint256 claimIndex, address calculator);

    modifier onlyPolicyBook() {
        require(policyBookRegistry.isPolicyBook(msg.sender), "CV: Not a PolicyBook");
        _;
    }

    function _isVoteAwaitingCalculation(uint256 index) internal view returns (bool) {
        uint256 claimIndex = _allVotesByIndexInst[index].claimIndex;

        return (!claimingRegistry.isClaimPending(claimIndex) &&
            _allVotesByIndexInst[index].status == VoteStatus.EXPOSED_PENDING);
    }

    function _isVoteAwaitingExposure(uint256 index) internal view returns (bool) {
        uint256 claimIndex = _allVotesByIndexInst[index].claimIndex;

        return (claimingRegistry.isClaimExposablyVotable(claimIndex) &&
            _allVotesByIndexInst[index].status == VoteStatus.ANONYMOUS_PENDING);
    }

    function _isVoteExpired(uint256 index) internal view returns (bool) {
        uint256 claimIndex = _allVotesByIndexInst[index].claimIndex;

        return (!claimingRegistry.isClaimExposablyVotable(claimIndex) &&
            !claimingRegistry.isClaimAnonymouslyVotable(claimIndex) &&
            _allVotesByIndexInst[index].status == VoteStatus.ANONYMOUS_PENDING);
    }

    function __ClaimVoting_init() external initializer {
        _voteIndex = 1;
    }

    function setDependencies(IContractsRegistry _contractsRegistry)
        external
        override
        onlyInjectorOrZero
    {
        priceFeed = IPriceFeed(_contractsRegistry.getPriceFeedContract());
        claimingRegistry = IClaimingRegistry(_contractsRegistry.getClaimingRegistryContract());
        policyBookRegistry = IPolicyBookRegistry(
            _contractsRegistry.getPolicyBookRegistryContract()
        );
        reputationSystem = IReputationSystem(_contractsRegistry.getReputationSystemContract());
        reinsurancePool = IReinsurancePool(_contractsRegistry.getReinsurancePoolContract());
        vBMI = IVBMI(_contractsRegistry.getVBMIContract());
        bmiToken = IERC20(_contractsRegistry.getBMIContract());
        daiToken = IERC20(_contractsRegistry.getDAIContract());
    }

    /// @notice this function needs user's BMI approval of this address (check policybook)
    function initializeVoting(
        address claimer,
        address policyBookAddress,
        uint256 coverTokens,
        uint256 reinsuranceTokensAmount,
        bool appeal
    ) external override onlyPolicyBook {
        require(coverTokens > 0, "CV: Claimer has no coverage");

        // this checks claim duplicate && appeal logic
        uint256 claimIndex = claimingRegistry.submitClaim(claimer, policyBookAddress, appeal);

        uint256 onePercentInBMIToLock = priceFeed.howManyBMIsInDAI(coverTokens.div(100));

        bmiToken.transferFrom(claimer, address(this), onePercentInBMIToLock); // needed approval

        reinsuranceTokensAmount = Math.min(reinsuranceTokensAmount, coverTokens.div(100));

        _votings[claimIndex].withdrawalAmount = coverTokens;
        _votings[claimIndex].lockedBMIAmount = onePercentInBMIToLock;
        _votings[claimIndex].reinsuranceTokensAmount = reinsuranceTokensAmount;
    }

    /// @dev check in BMIStaking when withdrawing, if true -> can withdraw
    function canWithdraw(address user) external view override returns (bool) {
        return _myNotCalculatedVotes[user].length() == 0;
    }

    /// @dev check when anonymously voting, if true -> can vote
    function canVote(address user) public view override returns (bool) {
        uint256 notCalculatedLength = _myNotCalculatedVotes[user].length();

        for (uint256 i = 0; i < notCalculatedLength; i++) {
            if (
                voteStatus(_allVotesToIndex[user][_myNotCalculatedVotes[user].at(i)]) ==
                VoteStatus.AWAITING_CALCULATION
            ) {
                return false;
            }
        }

        return true;
    }

    function countVotes(address user) external view override returns (uint256) {
        return _myVotes[user].length();
    }

    function voteStatus(uint256 index) public view override returns (VoteStatus) {
        require(_allVotesIndexes.contains(index), "CV: Vote doesn't exist");

        if (_isVoteAwaitingCalculation(index)) {
            return VoteStatus.AWAITING_CALCULATION;
        } else if (_isVoteAwaitingExposure(index)) {
            return VoteStatus.AWAITING_EXPOSURE;
        } else if (_isVoteExpired(index)) {
            return VoteStatus.EXPIRED;
        }

        return _allVotesByIndexInst[index].status;
    }

    /// @dev use with claimingRegistry.countPendingClaims()
    function whatCanIVoteFor(uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint256 _claimsCount, PublicClaimInfo[] memory _votablesInfo)
    {
        uint256 to = (offset.add(limit)).min(claimingRegistry.countPendingClaims()).max(offset);
        bool trustedVoter = reputationSystem.isTrustedVoter(msg.sender);

        _claimsCount = 0;

        _votablesInfo = new PublicClaimInfo[](to - offset);

        for (uint256 i = offset; i < to; i++) {
            uint256 index = claimingRegistry.pendingClaimIndexAt(i);

            if (
                _allVotesToIndex[msg.sender][index] == 0 &&
                claimingRegistry.claimOwner(index) != msg.sender &&
                claimingRegistry.isClaimAnonymouslyVotable(index) &&
                (!claimingRegistry.isClaimAppeal(index) || trustedVoter)
            ) {
                IClaimingRegistry.ClaimInfo memory claimInfo = claimingRegistry.claimInfo(index);

                _votablesInfo[_claimsCount].claimIndex = index;
                _votablesInfo[_claimsCount].claimer = claimInfo.claimer;
                _votablesInfo[_claimsCount].policyBookAddress = claimInfo.policyBookAddress;
                _votablesInfo[_claimsCount].appeal = claimInfo.appeal;
                _votablesInfo[_claimsCount].claimAmount = claimInfo.claimAmount;
                _votablesInfo[_claimsCount].time = claimInfo.dateSubmitted;

                _votablesInfo[_claimsCount].time = _votablesInfo[_claimsCount]
                    .time
                    .add(claimingRegistry.anonymousVotingDuration(index))
                    .sub(block.timestamp);

                _claimsCount++;
            }
        }
    }

    /// @dev use with claimingRegistry.countClaims()
    function allClaims(uint256 offset, uint256 limit)
        external
        view
        override
        returns (AllClaimInfo[] memory _allClaimsInfo)
    {
        uint256 to = (offset.add(limit)).min(claimingRegistry.countClaims()).max(offset);

        _allClaimsInfo = new AllClaimInfo[](to - offset);

        for (uint256 i = offset; i < to; i++) {
            uint256 index = claimingRegistry.claimIndexAt(i);

            IClaimingRegistry.ClaimInfo memory claimInfo = claimingRegistry.claimInfo(index);

            _allClaimsInfo[i - offset].publicClaimInfo.claimIndex = index;
            _allClaimsInfo[i - offset].publicClaimInfo.claimer = claimInfo.claimer;
            _allClaimsInfo[i - offset].publicClaimInfo.policyBookAddress = claimInfo
                .policyBookAddress;
            _allClaimsInfo[i - offset].publicClaimInfo.appeal = claimInfo.appeal;
            _allClaimsInfo[i - offset].publicClaimInfo.claimAmount = claimInfo.claimAmount;
            _allClaimsInfo[i - offset].publicClaimInfo.time = claimInfo.dateSubmitted;

            _allClaimsInfo[i - offset].finalVerdict = claimInfo.status;

            if (
                _allClaimsInfo[i - offset].finalVerdict == IClaimingRegistry.ClaimStatus.ACCEPTED
            ) {
                _allClaimsInfo[i - offset].finalClaimAmount = _votings[index]
                    .votedAverageWithdrawalAmount;
            }

            if (claimingRegistry.canClaimBeCalculatedByAnyone(index)) {
                _allClaimsInfo[i - offset].bmiCalculationReward = _getBMIRewardForCalculation(
                    index
                );
            }
        }
    }

    /// @dev use with claimingRegistry.countPolicyClaimerClaims()
    function myClaims(uint256 offset, uint256 limit)
        external
        view
        override
        returns (MyClaimInfo[] memory _myClaimsInfo)
    {
        uint256 to =
            (offset.add(limit)).min(claimingRegistry.countPolicyClaimerClaims(msg.sender)).max(
                offset
            );

        _myClaimsInfo = new MyClaimInfo[](to - offset);

        for (uint256 i = offset; i < to; i++) {
            uint256 index = claimingRegistry.claimOfOwnerIndexAt(msg.sender, i);

            IClaimingRegistry.ClaimInfo memory claimInfo = claimingRegistry.claimInfo(index);

            _myClaimsInfo[i - offset].index = index;
            _myClaimsInfo[i - offset].policyBookAddress = claimInfo.policyBookAddress;
            _myClaimsInfo[i - offset].appeal = claimInfo.appeal;
            _myClaimsInfo[i - offset].claimAmount = claimInfo.claimAmount;
            _myClaimsInfo[i - offset].finalVerdict = claimInfo.status;

            if (_myClaimsInfo[i - offset].finalVerdict == IClaimingRegistry.ClaimStatus.ACCEPTED) {
                _myClaimsInfo[i - offset].finalClaimAmount = _votings[index]
                    .votedAverageWithdrawalAmount;
            } else if (
                _myClaimsInfo[i - offset].finalVerdict ==
                IClaimingRegistry.ClaimStatus.AWAITING_CALCULATION
            ) {
                _myClaimsInfo[i - offset].bmiCalculationReward = _getBMIRewardForCalculation(
                    index
                );
            }
        }
    }

    /// @dev use with countVotes()
    function myVotes(uint256 offset, uint256 limit)
        external
        view
        override
        returns (MyVoteInfo[] memory _myVotesInfo)
    {
        uint256 to = (offset.add(limit)).min(_myVotes[msg.sender].length()).max(offset);

        _myVotesInfo = new MyVoteInfo[](to - offset);

        for (uint256 i = offset; i < to; i++) {
            VotingInst storage myVote = _allVotesByIndexInst[_myVotes[msg.sender].at(i)];

            uint256 index = myVote.claimIndex;

            IClaimingRegistry.ClaimInfo memory claimInfo = claimingRegistry.claimInfo(index);

            _myVotesInfo[i - offset].allClaimInfo.publicClaimInfo.claimIndex = index;
            _myVotesInfo[i - offset].allClaimInfo.publicClaimInfo.claimer = claimInfo.claimer;
            _myVotesInfo[i - offset].allClaimInfo.publicClaimInfo.policyBookAddress = claimInfo
                .policyBookAddress;
            _myVotesInfo[i - offset].allClaimInfo.publicClaimInfo.appeal = claimInfo.appeal;
            _myVotesInfo[i - offset].allClaimInfo.publicClaimInfo.claimAmount = claimInfo
                .claimAmount;
            _myVotesInfo[i - offset].allClaimInfo.publicClaimInfo.time = claimInfo.dateSubmitted;

            _myVotesInfo[i - offset].allClaimInfo.finalVerdict = claimInfo.status;

            if (
                _myVotesInfo[i - offset].allClaimInfo.finalVerdict ==
                IClaimingRegistry.ClaimStatus.ACCEPTED
            ) {
                _myVotesInfo[i - offset].allClaimInfo.finalClaimAmount = _votings[index]
                    .votedAverageWithdrawalAmount;
            }

            _myVotesInfo[i - offset].suggestedAmount = myVote.suggestedAmount;
            _myVotesInfo[i - offset].status = voteStatus(_myVotes[msg.sender].at(i));

            if (_myVotesInfo[i - offset].status == VoteStatus.ANONYMOUS_PENDING) {
                _myVotesInfo[i - offset].time = claimInfo
                    .dateSubmitted
                    .add(claimingRegistry.anonymousVotingDuration(index))
                    .sub(block.timestamp);
            } else if (_myVotesInfo[i - offset].status == VoteStatus.AWAITING_EXPOSURE) {
                _myVotesInfo[i - offset].encryptedVote = myVote.encryptedVote;
                _myVotesInfo[i - offset].time = claimInfo
                    .dateSubmitted
                    .add(claimingRegistry.votingDuration(index))
                    .sub(block.timestamp);
            }
        }
    }

    /// @dev use with countVotes()
    function myVotesUpdates(uint256 offset, uint256 limit)
        external
        view
        override
        returns (
            uint256 _votesUpdatesCount,
            uint256[] memory _claimIndexes,
            VotesUpdatesInfo memory _myVotesUpdatesInfo
        )
    {
        uint256 to = (offset.add(limit)).min(_myVotes[msg.sender].length()).max(offset);
        _votesUpdatesCount = 0;

        _claimIndexes = new uint256[](to - offset);

        uint256 daiAmount;
        uint256 bmiAmount;
        uint256 bmiPenaltyAmount;
        uint256 newReputation;

        for (uint256 i = offset; i < to; i++) {
            uint256 claimIndex = _allVotesByIndexInst[_myVotes[msg.sender].at(i)].claimIndex;

            if (
                _myNotCalculatedVotes[msg.sender].contains(claimIndex) &&
                voteStatus(_allVotesToIndex[msg.sender][claimIndex]) ==
                VoteStatus.AWAITING_CALCULATION
            ) {
                _claimIndexes[_votesUpdatesCount] = claimIndex;
                uint256 oldReputation = reputationSystem.reputation(msg.sender);

                if (
                    _votings[claimIndex].votedYesPercentage >= PERCENTAGE_50 &&
                    _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]]
                        .suggestedAmount >
                    0
                ) {
                    (daiAmount, bmiAmount, newReputation) = _calculateMajorityYesVote(
                        claimIndex,
                        msg.sender,
                        oldReputation
                    );

                    _myVotesUpdatesInfo.reputationChange += int256(
                        newReputation.sub(oldReputation)
                    );
                } else if (
                    _votings[claimIndex].votedYesPercentage < PERCENTAGE_50 &&
                    _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]]
                        .suggestedAmount ==
                    0
                ) {
                    (bmiAmount, newReputation) = _calculateMajorityNoVote(
                        claimIndex,
                        msg.sender,
                        oldReputation
                    );

                    _myVotesUpdatesInfo.reputationChange += int256(
                        newReputation.sub(oldReputation)
                    );
                } else {
                    (bmiPenaltyAmount, newReputation) = _calculateMinorityVote(
                        claimIndex,
                        msg.sender,
                        oldReputation
                    );

                    _myVotesUpdatesInfo.reputationChange -= int256(
                        oldReputation.sub(newReputation)
                    );
                    _myVotesUpdatesInfo.stakeChange -= int256(bmiPenaltyAmount);
                }

                _myVotesUpdatesInfo.bmiReward = _myVotesUpdatesInfo.bmiReward.add(bmiAmount);
                _myVotesUpdatesInfo.daiReward = _myVotesUpdatesInfo.daiReward.add(daiAmount);

                _votesUpdatesCount++;
            }
        }
    }

    function _calculateAverages(
        uint256 claimIndex,
        uint256 stakedBMI,
        uint256 suggestedClaimAmount,
        uint256 reputationWithPrecision,
        bool votedFor
    ) internal {
        VotingResult storage info = _votings[claimIndex];

        if (votedFor) {
            uint256 votedPower = info.votedYesStakedBMIAmountWithReputation;
            uint256 voterPower = stakedBMI.mul(reputationWithPrecision);
            uint256 totalPower = votedPower.add(voterPower);

            uint256 votedSuggestedPrice =
                info.votedAverageWithdrawalAmount.mul(
                    votedPower.mul(PERCENTAGE_100).div(totalPower)
                );
            uint256 voterSuggestedPrice =
                suggestedClaimAmount.mul(voterPower.mul(PERCENTAGE_100).div(totalPower));

            info.votedAverageWithdrawalAmount = votedSuggestedPrice.add(voterSuggestedPrice).div(
                PERCENTAGE_100
            );
            info.votedYesStakedBMIAmountWithReputation = totalPower;
        } else {
            info.votedNoStakedBMIAmountWithReputation = info
                .votedNoStakedBMIAmountWithReputation
                .add(stakedBMI.mul(reputationWithPrecision));
        }

        info.allVotedStakedBMIAmount = info.allVotedStakedBMIAmount.add(stakedBMI);
    }

    function _modifyExposedVote(
        address voter,
        uint256 claimIndex,
        uint256 suggestedClaimAmount,
        uint256 stakedBMI,
        bool accept
    ) internal {
        uint256 index = _allVotesToIndex[voter][claimIndex];

        _myNotCalculatedVotes[voter].add(claimIndex);

        _allVotesByIndexInst[index].finalHash = 0;
        delete _allVotesByIndexInst[index].encryptedVote;

        _allVotesByIndexInst[index].suggestedAmount = suggestedClaimAmount;
        _allVotesByIndexInst[index].stakedBMIAmount = stakedBMI;
        _allVotesByIndexInst[index].accept = accept;
        _allVotesByIndexInst[index].status = VoteStatus.EXPOSED_PENDING;
    }

    function _addAnonymousVote(
        address voter,
        uint256 claimIndex,
        bytes32 finalHash,
        string memory encryptedVote
    ) internal {
        _myVotes[voter].add(_voteIndex);

        _allVotesByIndexInst[_voteIndex].claimIndex = claimIndex;
        _allVotesByIndexInst[_voteIndex].finalHash = finalHash;
        _allVotesByIndexInst[_voteIndex].encryptedVote = encryptedVote;
        _allVotesByIndexInst[_voteIndex].voter = voter;
        _allVotesByIndexInst[_voteIndex].voterReputation = reputationSystem.reputation(voter);
        // No need to set default ANONYMOUS_PENDING status

        _allVotesToIndex[voter][claimIndex] = _voteIndex;
        _allVotesIndexes.add(_voteIndex);

        _voteIndex++;
    }

    function anonymouslyVoteBatch(
        uint256[] calldata claimIndexes,
        bytes32[] calldata finalHashes,
        string[] calldata encryptedVotes
    ) external override {
        require(canVote(msg.sender), "CV: There are awaiting votes");
        require(
            claimIndexes.length == finalHashes.length &&
                claimIndexes.length == encryptedVotes.length,
            "CV: Length mismatches"
        );

        for (uint256 i = 0; i < claimIndexes.length; i++) {
            uint256 claimIndex = claimIndexes[i];

            require(
                claimingRegistry.isClaimAnonymouslyVotable(claimIndex),
                "CV: Anonymous voting is over"
            );
            require(
                claimingRegistry.claimOwner(claimIndex) != msg.sender,
                "CV: Voter is the claimer"
            );
            require(
                !claimingRegistry.isClaimAppeal(claimIndex) ||
                    reputationSystem.isTrustedVoter(msg.sender),
                "CV: Not a trusted voter"
            );
            require(
                _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]].finalHash == 0,
                "CV: Already voted for this claim"
            );

            _addAnonymousVote(msg.sender, claimIndex, finalHashes[i], encryptedVotes[i]);

            emit AnonymouslyVoted(claimIndex);
        }
    }

    function exposeVoteBatch(
        uint256[] calldata claimIndexes,
        uint256[] calldata suggestedClaimAmounts,
        bytes32[] calldata hashedSignaturesOfClaims
    ) external override {
        require(
            claimIndexes.length == suggestedClaimAmounts.length &&
                claimIndexes.length == hashedSignaturesOfClaims.length,
            "CV: Length mismatches"
        );

        for (uint256 i = 0; i < claimIndexes.length; i++) {
            uint256 claimIndex = claimIndexes[i];

            require(
                voteStatus(_allVotesToIndex[msg.sender][claimIndex]) ==
                    VoteStatus.AWAITING_EXPOSURE,
                "CV: Vote is not awaiting"
            );

            bytes32 finalHash =
                keccak256(
                    abi.encodePacked(
                        hashedSignaturesOfClaims[i],
                        _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]]
                            .encryptedVote,
                        suggestedClaimAmounts[i]
                    )
                );

            require(
                _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]].finalHash ==
                    finalHash,
                "CV: Data mismatches"
            );
            require(
                _votings[claimIndex].withdrawalAmount >= suggestedClaimAmounts[i],
                "CV: Amount succeds coverage"
            );

            uint256 stakedBMI = vBMI.balanceOf(msg.sender); // use canWithdaw function in vBMI staking

            require(stakedBMI > 0, "CV: 0 staked BMI");

            bool voteFor = (suggestedClaimAmounts[i] > 0);

            _calculateAverages(
                claimIndex,
                stakedBMI,
                suggestedClaimAmounts[i],
                _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]].voterReputation,
                voteFor
            );

            _modifyExposedVote(
                msg.sender,
                claimIndex,
                suggestedClaimAmounts[i],
                stakedBMI,
                voteFor
            );

            emit VoteExposed(claimIndex, msg.sender, suggestedClaimAmounts[i]);
        }
    }

    function _getRewardRatio(
        uint256 claimIndex,
        address voter,
        uint256 votedStakedBMIAmountWithReputation
    ) internal view returns (uint256) {
        uint256 voterBMI =
            _allVotesByIndexInst[_allVotesToIndex[voter][claimIndex]].stakedBMIAmount;
        uint256 voterReputation =
            _allVotesByIndexInst[_allVotesToIndex[voter][claimIndex]].voterReputation;

        return
            voterBMI.mul(voterReputation).mul(PERCENTAGE_100).div(
                votedStakedBMIAmountWithReputation
            );
    }

    function _calculateMajorityYesVote(
        uint256 claimIndex,
        address voter,
        uint256 oldReputation
    )
        internal
        view
        returns (
            uint256 _daiAmount,
            uint256 _bmiAmount,
            uint256 _newReputation
        )
    {
        VotingResult storage info = _votings[claimIndex];

        uint256 voterRatio =
            _getRewardRatio(claimIndex, voter, info.votedYesStakedBMIAmountWithReputation);

        if (claimingRegistry.claimStatus(claimIndex) == IClaimingRegistry.ClaimStatus.ACCEPTED) {
            // calculate DAI reward tokens sent to the voter (from reinsurance)
            _daiAmount = info.reinsuranceTokensAmount.mul(voterRatio).div(PERCENTAGE_100);
        } else {
            // calculate BMI reward tokens sent to the voter (from 1% locked)
            _bmiAmount = info.lockedBMIAmount.mul(voterRatio).div(PERCENTAGE_100);
        }

        _newReputation = reputationSystem.getNewReputation(oldReputation, info.votedYesPercentage);
    }

    function _calculateMajorityNoVote(
        uint256 claimIndex,
        address voter,
        uint256 oldReputation
    ) internal view returns (uint256 _bmiAmount, uint256 _newReputation) {
        VotingResult storage info = _votings[claimIndex];

        uint256 voterRatio =
            _getRewardRatio(claimIndex, voter, info.votedNoStakedBMIAmountWithReputation);

        // calculate BMI reward tokens sent to the voter (from 1% locked)
        _bmiAmount = info.lockedBMIAmount.mul(voterRatio).div(PERCENTAGE_100);

        _newReputation = reputationSystem.getNewReputation(
            oldReputation,
            PERCENTAGE_100.sub(info.votedYesPercentage)
        );
    }

    function _calculateMinorityVote(
        uint256 claimIndex,
        address voter,
        uint256 oldReputation
    ) internal view returns (uint256 _bmiPenalty, uint256 _newReputation) {
        uint256 minorityPercentageWithPrecision =
            Math.min(
                _votings[claimIndex].votedYesPercentage,
                PERCENTAGE_100.sub(_votings[claimIndex].votedYesPercentage)
            );

        if (minorityPercentageWithPrecision < PENALTY_THRESHOLD) {
            // calculate confiscated staked stkBMI tokens sent to reinsurance pool
            _bmiPenalty = Math.min(
                vBMI.balanceOf(voter),
                _allVotesByIndexInst[_allVotesToIndex[voter][claimIndex]]
                    .stakedBMIAmount
                    .mul(PENALTY_THRESHOLD.sub(minorityPercentageWithPrecision))
                    .div(PERCENTAGE_100)
            );
        }

        _newReputation = reputationSystem.getNewReputation(
            oldReputation,
            minorityPercentageWithPrecision
        );
    }

    function calculateVoterResultBatch(uint256[] calldata claimIndexes) external override {
        uint256 reputation = reputationSystem.reputation(msg.sender);

        for (uint256 i = 0; i < claimIndexes.length; i++) {
            uint256 claimIndex = claimIndexes[i];

            require(claimingRegistry.claimExists(claimIndex), "CV: Claim doesn't exist");
            require(_allVotesToIndex[msg.sender][claimIndex] != 0, "CV: No vote on this claim");
            require(
                voteStatus(_allVotesToIndex[msg.sender][claimIndex]) ==
                    VoteStatus.AWAITING_CALCULATION,
                "CV: Vote is not awaiting"
            );

            uint256 daiAmount;
            uint256 bmiAmount;
            VoteStatus status;

            if (
                _votings[claimIndex].votedYesPercentage >= PERCENTAGE_50 &&
                _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]].suggestedAmount > 0
            ) {
                (daiAmount, bmiAmount, reputation) = _calculateMajorityYesVote(
                    claimIndex,
                    msg.sender,
                    reputation
                );

                reinsurancePool.withdrawDAITo(msg.sender, daiAmount);
                bmiToken.transfer(msg.sender, bmiAmount);

                emit RewardsForVoteCalculationSent(msg.sender, bmiAmount);

                status = VoteStatus.MAJORITY;
            } else if (
                _votings[claimIndex].votedYesPercentage < PERCENTAGE_50 &&
                _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]].suggestedAmount == 0
            ) {
                (bmiAmount, reputation) = _calculateMajorityNoVote(
                    claimIndex,
                    msg.sender,
                    reputation
                );

                bmiToken.transfer(msg.sender, bmiAmount);

                emit RewardsForVoteCalculationSent(msg.sender, bmiAmount);

                status = VoteStatus.MAJORITY;
            } else {
                (bmiAmount, reputation) = _calculateMinorityVote(
                    claimIndex,
                    msg.sender,
                    reputation
                );

                vBMI.slashUserTokens(msg.sender, bmiAmount);

                status = VoteStatus.MINORITY;
            }

            _allVotesByIndexInst[_allVotesToIndex[msg.sender][claimIndex]].status = status;
            _myNotCalculatedVotes[msg.sender].remove(claimIndex);

            emit VoteCalculated(claimIndex, msg.sender, status);
        }

        reputationSystem.setNewReputation(msg.sender, reputation);
    }

    function _getBMIRewardForCalculation(uint256 claimIndex) internal view returns (uint256) {
        uint256 lockedBMIs = _votings[claimIndex].lockedBMIAmount;
        uint256 timeElapsed =
            claimingRegistry.claimSubmittedTime(claimIndex).add(
                claimingRegistry.anyoneCanCalculateClaimResultAfter(claimIndex)
            );

        if (claimingRegistry.canClaimBeCalculatedByAnyone(claimIndex)) {
            timeElapsed = block.timestamp.sub(timeElapsed);
        } else {
            timeElapsed = timeElapsed.sub(block.timestamp);
        }

        return
            Math.min(
                lockedBMIs,
                lockedBMIs.mul(timeElapsed.mul(CALCULATION_REWARD_PER_DAY.div(1 days))).div(
                    PERCENTAGE_100
                )
            );
    }

    function _sendRewardsForCalculationTo(uint256 claimIndex, address calculator) internal {
        uint256 reward = _getBMIRewardForCalculation(claimIndex);

        _votings[claimIndex].lockedBMIAmount = _votings[claimIndex].lockedBMIAmount.sub(reward);

        bmiToken.transfer(calculator, reward);

        emit RewardsForClaimCalculationSent(calculator, reward);
    }

    function calculateVotingResultBatch(uint256[] calldata claimIndexes) external override {
        for (uint256 i = 0; i < claimIndexes.length; i++) {
            uint256 claimIndex = claimIndexes[i];

            // claim existence is checked in claimStatus function
            require(
                claimingRegistry.claimStatus(claimIndex) ==
                    IClaimingRegistry.ClaimStatus.AWAITING_CALCULATION,
                "CV: Claim is not awaiting"
            );
            require(
                claimingRegistry.canClaimBeCalculatedByAnyone(claimIndex) ||
                    claimingRegistry.claimOwner(claimIndex) == msg.sender,
                "CV: Not allowed to calculate"
            );

            _sendRewardsForCalculationTo(claimIndex, msg.sender);

            emit ClaimCalculated(claimIndex, msg.sender);

            // if voted < 10% supply of vBMI
            if (
                vBMI.totalSupply() == 0 ||
                (vBMI.totalSupply().mul(QUORUM).div(PERCENTAGE_100) >
                    _votings[claimIndex].allVotedStakedBMIAmount)
            ) {
                // reject & use locked BMI for rewards
                claimingRegistry.rejectClaim(claimIndex);
            } else {
                uint256 votedYesPower = _votings[claimIndex].votedYesStakedBMIAmountWithReputation;
                uint256 votedNoPower = _votings[claimIndex].votedNoStakedBMIAmountWithReputation;
                uint256 totalPower = votedYesPower.add(votedNoPower);

                _votings[claimIndex].votedYesPercentage = votedYesPower.mul(PERCENTAGE_100).div(
                    totalPower
                );

                if (_votings[claimIndex].votedYesPercentage >= APPROVAL_PERCENTAGE) {
                    // approve + send DAI & return locked BMI to the claimer
                    claimingRegistry.acceptClaim(claimIndex);

                    IClaimingRegistry.ClaimInfo memory claimInfo =
                        claimingRegistry.claimInfo(claimIndex);

                    IPolicyBook(claimInfo.policyBookAddress).commitClaim(
                        claimInfo.claimer,
                        _votings[claimIndex].votedAverageWithdrawalAmount
                    );

                    bmiToken.transfer(claimInfo.claimer, _votings[claimIndex].lockedBMIAmount);
                } else {
                    // reject & use locked BMI for rewards
                    claimingRegistry.rejectClaim(claimIndex);
                }
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

uint256 constant SECONDS_IN_THE_YEAR = 365 * 24 * 60 * 60; // 365 days * 24 hours * 60 minutes * 60 seconds
uint256 constant MAX_INT = 2**256 - 1;

uint256 constant DECIMALS = 10**18;

uint256 constant PRECISION = 10**25;
uint256 constant PERCENTAGE_100 = 100 * PRECISION;

uint256 constant ONE_MONTH = 30 days;

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

import "../interfaces/IContractsRegistry.sol";

abstract contract AbstractDependant {
    /// @dev keccak256(AbstractDependant.setInjector(address)) - 1
    bytes32 private constant _INJECTOR_SLOT =
        0xd6b8f2e074594ceb05d47c27386969754b6ad0c15e5eb8f691399cd0be980e76;

    modifier onlyInjectorOrZero() {
        address _injector = injector();

        require(_injector == address(0) || _injector == msg.sender, "Dependant: Not an injector");
        _;
    }

    function setInjector(address _injector) external onlyInjectorOrZero {
        bytes32 slot = _INJECTOR_SLOT;

        assembly {
            sstore(slot, _injector)
        }
    }

    /// @dev has to apply onlyInjectorOrZero() modifier
    function setDependencies(IContractsRegistry) external virtual;

    function injector() public view returns (address _injector) {
        bytes32 slot = _INJECTOR_SLOT;

        assembly {
            _injector := sload(slot)
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IClaimingRegistry.sol";

interface IClaimVoting {
    enum VoteStatus {
        ANONYMOUS_PENDING,
        AWAITING_EXPOSURE,
        EXPIRED,
        EXPOSED_PENDING,
        AWAITING_CALCULATION,
        MINORITY,
        MAJORITY
    }

    struct VotingResult {
        uint256 withdrawalAmount;
        uint256 lockedBMIAmount;
        uint256 reinsuranceTokensAmount;
        uint256 votedAverageWithdrawalAmount;
        uint256 votedYesStakedBMIAmountWithReputation;
        uint256 votedNoStakedBMIAmountWithReputation;
        uint256 allVotedStakedBMIAmount;
        uint256 votedYesPercentage;
    }

    struct VotingInst {
        uint256 claimIndex;
        bytes32 finalHash;
        string encryptedVote;
        address voter;
        uint256 voterReputation;
        uint256 suggestedAmount;
        uint256 stakedBMIAmount;
        bool accept;
        VoteStatus status;
    }

    struct MyClaimInfo {
        uint256 index;
        address policyBookAddress;
        bool appeal;
        uint256 claimAmount;
        IClaimingRegistry.ClaimStatus finalVerdict;
        uint256 finalClaimAmount;
        uint256 bmiCalculationReward;
    }

    struct PublicClaimInfo {
        uint256 claimIndex;
        address claimer;
        address policyBookAddress;
        bool appeal;
        uint256 claimAmount;
        uint256 time;
    }

    struct AllClaimInfo {
        PublicClaimInfo publicClaimInfo;
        IClaimingRegistry.ClaimStatus finalVerdict;
        uint256 finalClaimAmount;
        uint256 bmiCalculationReward;
    }

    struct MyVoteInfo {
        AllClaimInfo allClaimInfo;
        string encryptedVote;
        uint256 suggestedAmount;
        VoteStatus status;
        uint256 time;
    }

    struct VotesUpdatesInfo {
        uint256 bmiReward;
        uint256 daiReward;
        int256 reputationChange;
        int256 stakeChange;
    }

    /// @notice starts the voting process
    function initializeVoting(
        address claimer,
        address policyBookAddress,
        uint256 coverTokens,
        uint256 reinsuranceTokensAmount,
        bool appeal
    ) external;

    /// @notice returns true if the user has no PENDING votes
    function canWithdraw(address user) external view returns (bool);

    /// @notice returns true if the user has no AWAITING_CALCULATION votes
    function canVote(address user) external view returns (bool);

    /// @notice returns how many votes the user has
    function countVotes(address user) external view returns (uint256);

    /// @notice returns status of the vote
    function voteStatus(uint256 index) external view returns (VoteStatus);

    /// @notice returns a list of claims that are votable for msg.sender
    function whatCanIVoteFor(uint256 offset, uint256 limit)
        external
        returns (uint256 _claimsCount, PublicClaimInfo[] memory _votablesInfo);

    /// @notice returns info list of ALL claims
    function allClaims(uint256 offset, uint256 limit)
        external
        view
        returns (AllClaimInfo[] memory _allClaimsInfo);

    /// @notice returns info list of claims of msg.sender
    function myClaims(uint256 offset, uint256 limit)
        external
        view
        returns (MyClaimInfo[] memory _myClaimsInfo);

    /// @notice returns info list of claims that are voted by msg.sender
    function myVotes(uint256 offset, uint256 limit)
        external
        view
        returns (MyVoteInfo[] memory _myVotesInfo);

    /// @notice returns an array of votes that can be calculated + update information
    function myVotesUpdates(uint256 offset, uint256 limit)
        external
        view
        returns (
            uint256 _votesUpdatesCount,
            uint256[] memory _claimIndexes,
            VotesUpdatesInfo memory _myVotesUpdatesInfo
        );

    /// @notice anonymously votes (result used later in exposeVote())
    function anonymouslyVoteBatch(
        uint256[] calldata claimIndexes,
        bytes32[] calldata finalHashes,
        string[] calldata encryptedVotes
    ) external;

    /// @notice exposes votes of anonymous votings
    function exposeVoteBatch(
        uint256[] calldata claimIndexes,
        uint256[] calldata suggestedClaimAmounts,
        bytes32[] calldata hashedSignaturesOfClaims
    ) external;

    /// @notice calculates results of votes
    function calculateVoterResultBatch(uint256[] calldata claimIndexes) external;

    /// @notice calculates results of claims
    function calculateVotingResultBatch(uint256[] calldata claimIndexes) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";

interface IClaimingRegistry {
    enum ClaimStatus {
        CAN_CLAIM,
        UNCLAIMABLE,
        PENDING,
        AWAITING_CALCULATION,
        REJECTED_CAN_APPEAL,
        REJECTED,
        ACCEPTED
    }

    struct ClaimInfo {
        address claimer;
        address policyBookAddress;
        bool appeal;
        uint256 dateSubmitted;
        ClaimStatus status;
        uint256 claimAmount;
    }

    /// @notice returns anonymous voting duration
    function anonymousVotingDuration(uint256 index) external view returns (uint256);

    /// @notice returns the whole voting duration
    function votingDuration(uint256 index) external view returns (uint256);

    /// @notice returns how many time should pass before anyone could calculate a claim result
    function anyoneCanCalculateClaimResultAfter(uint256 index) external view returns (uint256);

    /// @notice submits new PolicyBook claim for the user
    function submitClaim(
        address user,
        address policyBookAddress,
        bool appeal
    ) external returns (uint256);

    /// @notice returns true if the claim with this index exists
    function claimExists(uint256 index) external view returns (bool);

    /// @notice returns claim submition time
    function claimSubmittedTime(uint256 index) external view returns (uint256);

    /// @notice returns true if the claim is anonymously votable
    function isClaimAnonymouslyVotable(uint256 index) external view returns (bool);

    /// @notice returns true if the claim is exposably votable
    function isClaimExposablyVotable(uint256 index) external view returns (bool);

    /// @notice returns true if a claim can be calculated by anyone
    function canClaimBeCalculatedByAnyone(uint256 index) external view returns (bool);

    /// @notice returns true if this claim is pending or awaiting
    function isClaimPending(uint256 index) external view returns (bool);

    /// @notice returns how many claims the holder has
    function countPolicyClaimerClaims(address user) external view returns (uint256);

    /// @notice returns how many pending claims are there
    function countPendingClaims() external view returns (uint256);

    /// @notice returns how many claims are there
    function countClaims() external view returns (uint256);

    /// @notice returns a claim index of it's claimer and an ordinal number
    function claimOfOwnerIndexAt(address claimer, uint256 orderIndex)
        external
        view
        returns (uint256);

    /// @notice returns pending claim index by its ordinal index
    function pendingClaimIndexAt(uint256 orderIndex) external view returns (uint256);

    /// @notice returns claim index by its ordinal index
    function claimIndexAt(uint256 orderIndex) external view returns (uint256);

    /// @notice returns current active claim index by policybook and claimer
    function claimIndex(address claimer, address policyBookAddress)
        external
        view
        returns (uint256);

    /// @notice returns true if the claim is appealed
    function isClaimAppeal(uint256 index) external view returns (bool);

    /// @notice returns current status of a claim
    function policyStatus(address claimer, address policyBookAddress)
        external
        view
        returns (ClaimStatus);

    /// @notice returns current status of a claim
    function claimStatus(uint256 index) external view returns (ClaimStatus);

    /// @notice returns the claim owner
    function claimOwner(uint256 index) external view returns (address);

    /// @notice returns claim info by its index
    function claimInfo(uint256 index) external view returns (ClaimInfo memory _claimInfo);

    /// @notice marks the user's claim as Accepted
    function acceptClaim(uint256 index) external;

    /// @notice marks the user's claim as Rejected
    function rejectClaim(uint256 index) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface IContractsRegistry {
    function getUniswapRouterContract() external view returns (address);

    function getUniswapBMIToETHPairContract() external view returns (address);

    function getWETHContract() external view returns (address);

    function getDAIContract() external view returns (address);

    function getBMIContract() external view returns (address);

    function getPriceFeedContract() external view returns (address);

    function getPolicyBookRegistryContract() external view returns (address);

    function getPolicyBookFabricContract() external view returns (address);

    function getBMIDAIStakingContract() external view returns (address);

    function getRewardsGeneratorContract() external view returns (address);

    function getLiquidityMiningNFTContract() external view returns (address);

    function getLiquidityMiningContract() external view returns (address);

    function getClaimingRegistryContract() external view returns (address);

    function getPolicyRegistryContract() external view returns (address);

    function getLiquidityRegistryContract() external view returns (address);

    function getClaimVotingContract() external view returns (address);

    function getReinsurancePoolContract() external view returns (address);

    function getPolicyBookAdminContract() external view returns (address);

    function getPolicyQuoteContract() external view returns (address);

    function getBMIStakingContract() external view returns (address);

    function getSTKBMIContract() external view returns (address);

    function getVBMIContract() external view returns (address);

    function getLiquidityMiningStakingContract() external view returns (address);

    function getReputationSystemContract() external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";

interface IPolicyBook {
    enum WithdrawalStatus {NONE, PENDING, READY, EXPIRED}

    struct PolicyHolder {
        uint256 coverTokens;
        uint256 startEpochNumber;
        uint256 endEpochNumber;
        uint256 payed;
    }

    struct WithdrawalInfo {
        uint256 withdrawalAmount;
        uint256 readyToWithdrawDate;
        bool withdrawalAllowed;
    }

    function EPOCH_DURATION() external view returns (uint256);

    function READY_TO_WITHDRAW_PERIOD() external view returns (uint256);

    function whitelisted() external view returns (bool);

    function epochStartTime() external view returns (uint256);

    // @TODO: should we let DAO to change contract address?
    /// @notice Returns address of contract this PolicyBook covers, access: ANY
    /// @return _contract is address of covered contract
    function insuranceContractAddress() external view returns (address _contract);

    /// @notice Returns type of contract this PolicyBook covers, access: ANY
    /// @return _type is type of contract
    function contractType() external view returns (IPolicyBookFabric.ContractType _type);

    function totalLiquidity() external view returns (uint256);

    function totalCoverTokens() external view returns (uint256);

    function withdrawalsInfo(address _userAddr)
        external
        view
        returns (
            uint256 _withdrawalAmount,
            uint256 _readyToWithdrawDate,
            bool _withdrawalAllowed
        );

    function __PolicyBook_init(
        address _insuranceContract,
        IPolicyBookFabric.ContractType _contractType,
        string calldata _description,
        string calldata _projectSymbol
    ) external;

    function whitelist(bool _whitelisted) external;

    /// @notice get DAI equivalent
    function convertDAIXToDAI(uint256 _amount) external view returns (uint256);

    /// @notice get DAIx equivalent
    function convertDAIToDAIX(uint256 _amount) external view returns (uint256);

    /// @notice returns how many BMI tokens needs to approve in order to submit a claim
    function getClaimApprovalAmount(address user) external view returns (uint256);

    /// @notice submits new claim of the policy book
    function submitClaimAndInitializeVoting() external;

    /// @notice submits new appeal claim of the policy book
    function submitAppealAndInitializeVoting() external;

    /// @notice updates info on claim acceptance
    function commitClaim(address claimer, uint256 claimAmount) external;

    /// @notice function to get precise current cover and liquidity
    function getNewCoverAndLiquidity()
        external
        view
        returns (uint256 newTotalCoverTokens, uint256 newTotalLiquidity);

    /// @notice view function to get precise policy price
    function getPolicyPrice(uint256 _epochsNumber, uint256 _coverTokens)
        external
        view
        returns (uint256 totalSeconds, uint256 totalPrice);

    function buyPolicyFor(
        address _buyer,
        uint256 _epochsNumber,
        uint256 _coverTokens
    ) external;

    /// @notice Let user to buy policy by supplying DAI, access: ANY
    /// @param _durationSeconds is number of seconds to cover
    /// @param _coverTokens is number of tokens to cover
    function buyPolicy(uint256 _durationSeconds, uint256 _coverTokens) external;

    function updateEpochsInfo() external;

    function secondsToEndCurrentEpoch() external view returns (uint256);

    /// @notice Let user to add liquidity by supplying DAI, access: ANY
    /// @param _liqudityAmount is amount of DAI tokens to secure
    function addLiquidity(uint256 _liqudityAmount) external;

    /// @notice Let eligible contracts add liqiudity for another user by supplying DAI
    /// @param _liquidityHolderAddr is address of address to assign cover
    /// @param _liqudityAmount is amount of DAI tokens to secure
    function addLiquidityFor(address _liquidityHolderAddr, uint256 _liqudityAmount) external;

    function addLiquidityAndStake(uint256 _liquidityAmount, uint256 _bmiDAIxAmount) external;

    function getAvailableDAIXWithdrawalAmount(address _userAddr) external view returns (uint256);

    function getWithdrawalStatus(address _userAddr) external view returns (WithdrawalStatus);

    function requestWithdrawal(uint256 _tokensToWithdraw) external;

    function requestWithdrawalWithPermit(
        uint256 _tokensToWithdraw,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external;

    function unlockTokens() external;

    /// @notice Let user to withdraw deposited liqiudity, access: ANY
    function withdrawLiquidity() external returns (uint256);

    /// @notice Getting user stats, access: ANY
    function userStats(address _user) external view returns (PolicyHolder memory);

    /// @notice Getting number stats, access: ANY
    /// @return _maxCapacities is a max token amount that a user can buy
    /// @return _totalDaiLiquidity is PolicyBook's liquidity
    /// @return _annualProfitYields is its APY
    /// @return _annualInsuranceCost is percentage of cover tokens that is required to be payed for 1 year of insurance
    function numberStats()
        external
        view
        returns (
            uint256 _maxCapacities,
            uint256 _totalDaiLiquidity,
            uint256 _annualProfitYields,
            uint256 _annualInsuranceCost
        );

    /// @notice Getting info, access: ANY
    /// @return _symbol is the symbol of PolicyBook (bmiDaiX)
    /// @return _insuredContract is an addres of insured contract
    /// @return _contractType is a type of insured contract
    /// @return _whitelisted is a state of whitelisting
    function info()
        external
        view
        returns (
            string memory _symbol,
            address _insuredContract,
            IPolicyBookFabric.ContractType _contractType,
            bool _whitelisted
        );
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

interface IPolicyBookFabric {
    enum ContractType {STABLECOIN, DEFI, CONTRACT, EXCHANGE}

    /// @notice Create new Policy Book contract, access: ANY
    /// @param _contract is Contract to create policy book for
    /// @param _contractType is Contract to create policy book for
    /// @param _description is bmiDAIx token desription for this policy book
    /// @param _projectSymbol replaces x in bmiDAIx token symbol
    /// @param _initialDeposit is an amount user deposits on creation (addLiquidity())
    /// @return _policyBook is address of created contract
    function create(
        address _contract,
        ContractType _contractType,
        string calldata _description,
        string calldata _projectSymbol,
        uint256 _initialDeposit
    ) external returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";

interface IPolicyBookRegistry {
    struct PolicyBookStats {
        string symbol;
        address insuredContract;
        IPolicyBookFabric.ContractType contractType;
        uint256 maxCapacity;
        uint256 totalDaiLiquidity;
        uint256 APY;
        uint256 annualInsuranceCost;
        bool whitelisted;
    }

    /// @notice Adds PolicyBook to registry, access: PolicyFabric
    function add(address insuredContract, address policyBook) external;

    /// @notice returns required allowances for the policybooks
    function getPoliciesPrices(
        address[] calldata policyBooks,
        uint256[] calldata epochsNumbers,
        uint256[] calldata coversTokens
    ) external view returns (uint256[] memory _durations, uint256[] memory _allowances);

    /// @notice Buys a batch of policies
    function buyPolicyBatch(
        address[] calldata policyBooks,
        uint256[] calldata epochsNumbers,
        uint256[] calldata coversTokens
    ) external;

    /// @notice Checks if provided address is a PolicyBook
    function isPolicyBook(address policyBook) external view returns (bool);

    /// @notice Returns number of registered PolicyBooks, access: ANY
    function count() external view returns (uint256);

    /// @notice Listing registered PolicyBooks, access: ANY
    /// @return _policyBooksArr is array of registered PolicyBook addresses
    function list(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _policyBooksArr);

    /// @notice Listing registered PolicyBooks, access: ANY
    function listWithStats(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory _policyBooksArr, PolicyBookStats[] memory _stats);

    /// @notice Return existing Policy Book contract, access: ANY
    /// @param insuredContract is contract address to lookup for created IPolicyBook
    function policyBookFor(address insuredContract) external view returns (address);

    /// @notice Getting stats from policy books, access: ANY
    /// @param policyBooks is list of PolicyBooks addresses
    function stats(address[] calldata policyBooks)
        external
        view
        returns (PolicyBookStats[] memory _stats);

    /// @notice Getting stats from policy books, access: ANY
    /// @param insuredContracts is list of insuredContracts in registry
    function statsByInsuredContracts(address[] calldata insuredContracts)
        external
        view
        returns (PolicyBookStats[] memory _stats);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface IReinsurancePool {
    function withdrawBMITo(address to, uint256 amount) external;

    function withdrawDAITo(address to, uint256 amount) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface IReputationSystem {
    /// @notice sets new reputation for the voter
    function setNewReputation(address voter, uint256 newReputation) external;

    /// @notice returns voter's new reputation
    function getNewReputation(address voter, uint256 percentageWithPrecision)
        external
        view
        returns (uint256);

    /// @notice alternative way of knowing new reputation
    function getNewReputation(uint256 voterReputation, uint256 percentageWithPrecision)
        external
        pure
        returns (uint256);

    /// @notice returns true if the user voted at least once
    function hasVotedOnce(address user) external view returns (bool);

    /// @notice returns true if user's reputation is grater than or equal to trusted voter threshold
    function isTrustedVoter(address user) external view returns (bool);

    /// @notice this function returns reputation threshold multiplied by 10**25
    function getTrustedVoterReputationThreshold() external view returns (uint256);

    /// @notice this function returns reputation multiplied by 10**25
    function reputation(address user) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

interface IPriceFeed {
    function howManyBMIsInDAI(uint256 daiAmount) external view returns (uint256);

    function howManyDAIsInBMI(uint256 bmiAmount) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IVBMI is IERC20Upgradeable {
    function lockStkBMI(uint256 amount) external;

    function unlockStkBMI(uint256 amount) external;

    function slashUserTokens(address user, uint256 amount) external;
}

// SPDX-License-Identifier: MIT

// solhint-disable-next-line compiler-version
pragma solidity >=0.4.24 <0.8.0;


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
        require(_initializing || _isConstructor() || !_initialized, "Initializable: contract is already initialized");

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

    /// @dev Returns true if and only if the function is running in the constructor
    function _isConstructor() private view returns (bool) {
        // extcodesize checks the size of the code stored in an address, and
        // address returns the current address. Since the code is still not
        // deployed when running a constructor, any checks on its code size will
        // yield zero, making it an effective way to detect if a contract is
        // under construction or not.
        address self = address(this);
        uint256 cs;
        // solhint-disable-next-line no-inline-assembly
        assembly { cs := extcodesize(self) }
        return cs == 0;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

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

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow, so we distribute
        return (a / 2) + (b / 2) + ((a % 2 + b % 2) / 2);
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
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
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
     *
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
     *
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
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
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
     *
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
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
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