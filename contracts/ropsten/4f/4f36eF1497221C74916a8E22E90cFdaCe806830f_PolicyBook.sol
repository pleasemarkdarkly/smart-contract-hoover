// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

uint256 constant SECONDS_IN_THE_YEAR = 365 * 24 * 60 * 60; // 365 days * 24 hours * 60 minutes * 60 seconds
uint256 constant MAX_INT = 2**256 - 1;

uint256 constant PRECISION = 10**25;
uint256 constant PERCENTAGE_100 = 100 * PRECISION;

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./tokens/erc20permit-upgradable/ERC20PermitUpgradeable.sol";
import "./interfaces/helpers/IPriceFeed.sol";
import "./interfaces/IPolicyBook.sol";
import "./interfaces/IBMIDAIStaking.sol";
import "./interfaces/IContractsRegistry.sol";
import "./interfaces/IPolicyRegistry.sol";
import "./interfaces/IClaimVoting.sol";
import "./interfaces/IClaimingRegistry.sol";
import "./interfaces/ILiquidityMining.sol";
import "./interfaces/IPolicyQuote.sol";
import "./interfaces/IRewardsGenerator.sol";
import "./interfaces/ILiquidityRegistry.sol";

import "./abstract/AbstractDependant.sol";

import "./Globals.sol";
import "./helpers/Queue.sol";

contract PolicyBook is IPolicyBook, ERC20PermitUpgradeable, AbstractDependant {
  using SafeMath for uint256;
  using Math for uint256;
  using Queue for Queue.UniqueAddressQueue;

  uint256 public constant PROTOCOL_PERCENTAGE = 20 * PRECISION;

  uint256 public constant RISKY_UTILIZATION_RATIO = 70 * PRECISION;
  uint256 public constant MODERATE_UTILIZATION_RATIO = 30 * PRECISION;

  uint256 public constant MAX_USERS_TO_UPDATE = 100;

  uint256 public constant PREMIUM_DISTRIBUTION_EPOCH = 3600; // 1 days
  uint256 public constant MAX_PREMIUM_DISTRIBUTION_EPOCHS = 90;

  uint256 public constant MINIMUM_REWARD = 25 * PRECISION; // 0.25
  uint256 public constant MAXIMUM_REWARD = 2 * PERCENTAGE_100; // 2.0
  uint256 public constant BASE_REWARD = PERCENTAGE_100; // 1.0

  uint256 public constant override EPOCH_DURATION = 1 days; // 1 weeks

  bool public override whitelisted;

  uint256 public override epochStartTime;
  uint256 public currentEpochNumber;  

  uint256 public constant WITHDRAWAL_PERIOD = 600; // 8 days
  uint256 public constant override READY_TO_WITHDRAW_PERIOD = 300; // 2 days
  uint256 public constant NEEDED_TIME_AFTER_LM = 0; // 2 weeks

  uint256 public lastPremiumDistributionEpoch;
  int256 public lastPremiumDistributionAmount;

  address public override insuranceContractAddress;
  IPolicyBookFabric.ContractType public override contractType;
  
  IPriceFeed public priceFeed;
  IERC20 public daiToken;
  IPolicyRegistry public policyRegistry;  
  IBMIDAIStaking public bmiDaiStaking;
  IRewardsGenerator public rewardsGenerator;
  ILiquidityMining public liquidityMining;
  IClaimVoting public claimVoting;
  IClaimingRegistry public claimingRegistry;
  ILiquidityRegistry public liquidityRegistry;
  address public reinsurancePoolAddress;  
  IPolicyQuote public policyQuote;
  address public policyBookAdmin;

  uint256 public override totalLiquidity;
  uint256 public override totalCoverTokens;
  uint256 public override aggregatedQueueAmount;

  Queue.UniqueAddressQueue private withdrawalQueue;

  mapping(address => WithdrawalInfo) public override withdrawalsInfo;
  mapping(address => PolicyHolder) public policyHolders;
  mapping(address => uint256) public liquidityFromLM;
  mapping(uint256 => uint256) public epochAmounts;
  mapping(uint256 => int256) public premiumDistributionDeltas;

  event AddLiquidity(address _liquidityHolder, uint256 _liquidityAmount, uint256 _newTotalLiquidity);
  event RequestWithdraw(address _liquidityHolder, uint256 _tokensToWithdraw, uint256 _readyToWithdrawDate);
  event WithdrawLiquidity(address _liquidityHolder, uint256 _tokensToWithdraw, uint256 _newTotalLiquidity);
  event BuyPolicy(address _policyHolder, uint256 _coverTokens, uint256 _price, uint256 _newTotalCoverTokens);
  event DistributionManuallyTriggered(address indexed caller, uint256 epochs);

  modifier onlyLiquidityMining() {
    require(_msgSender() == address(liquidityMining), "PB: Not a liquidity mining");
    _;
  }

  modifier onlyClaimVoting() {
    require(_msgSender() == address(claimVoting), "PB: Not a ClaimVoting");
    _;
  }

  modifier onlyPolicyBookAdmin() {
    require(_msgSender() == policyBookAdmin, "PB: Not a PolicyBookAdmin");
    _;
  }

  modifier updateBMIDAIXStakingReward() {
    _;

    uint256 rewardMultiplier = BASE_REWARD;

    if (totalCoverTokens > 0 && totalLiquidity > 0) {
      uint256 utilizationRatio = totalCoverTokens.mul(PERCENTAGE_100).div(totalLiquidity);

      if (utilizationRatio < MODERATE_UTILIZATION_RATIO) {
        rewardMultiplier = 
          Math.max(utilizationRatio, PRECISION).sub(PRECISION).mul(BASE_REWARD.sub(MINIMUM_REWARD))
          .div(MODERATE_UTILIZATION_RATIO)
          .add(MINIMUM_REWARD);
      } else if (utilizationRatio > RISKY_UTILIZATION_RATIO) {
        rewardMultiplier = 
          MAXIMUM_REWARD.sub(BASE_REWARD).mul(utilizationRatio.sub(RISKY_UTILIZATION_RATIO))
          .div(PERCENTAGE_100.sub(RISKY_UTILIZATION_RATIO))
          .add(BASE_REWARD);
      }
    }

    rewardsGenerator.updatePolicyBookShare(rewardMultiplier.div(10 ** 22)); // 5 decimal places
  }

  modifier withPremiumsDistribution() {
    _distributePremiums();
    _;
  }
  
  function __PolicyBook_init(
    address _insuranceContract,
    IPolicyBookFabric.ContractType _contractType,    
    string calldata _description,
    string calldata _projectSymbol    
  ) external override initializer {    
    string memory fullSymbol = string(abi.encodePacked("bmiDAI", _projectSymbol));
    __ERC20Permit_init(fullSymbol);
    __ERC20_init(_description, fullSymbol);

    insuranceContractAddress = _insuranceContract;
    contractType = _contractType;

    epochStartTime = block.timestamp;
    currentEpochNumber = 1;    
    
    lastPremiumDistributionEpoch = getDistributionEpoch();   
  }

  function setDependencies(IContractsRegistry _contractsRegistry) external override onlyInjectorOrZero { 
    priceFeed = IPriceFeed(_contractsRegistry.getPriceFeedContract());
    daiToken = IERC20(_contractsRegistry.getDAIContract());
    bmiDaiStaking = IBMIDAIStaking(_contractsRegistry.getBMIDAIStakingContract());
    rewardsGenerator = IRewardsGenerator(_contractsRegistry.getRewardsGeneratorContract());
    liquidityMining = ILiquidityMining(_contractsRegistry.getLiquidityMiningContract());
    claimVoting = IClaimVoting(_contractsRegistry.getClaimVotingContract());
    policyRegistry = IPolicyRegistry(_contractsRegistry.getPolicyRegistryContract());
    reinsurancePoolAddress = _contractsRegistry.getReinsurancePoolContract();
    policyQuote = IPolicyQuote(_contractsRegistry.getPolicyQuoteContract());
    claimingRegistry = IClaimingRegistry(_contractsRegistry.getClaimingRegistryContract());
    policyBookAdmin = _contractsRegistry.getPolicyBookAdminContract();
    liquidityRegistry = ILiquidityRegistry(_contractsRegistry.getLiquidityRegistryContract());
  }

  function whitelist(bool _whitelisted) external override onlyPolicyBookAdmin {
    whitelisted = _whitelisted;
  }

  function getDistributionEpoch() public view returns (uint256) {
    return block.timestamp / PREMIUM_DISTRIBUTION_EPOCH;
  }

  function getDAIToDAIxRatio() public view returns (uint256) {
    uint256 _currentTotalSupply = totalSupply();

    if (_currentTotalSupply == 0) {
      return PERCENTAGE_100;
    }

    return totalLiquidity.mul(PERCENTAGE_100).div(_currentTotalSupply);
  }

  function convertDAIXtoDAI(uint256 _amount) public view override returns (uint256) {
    return _amount.mul(getDAIToDAIxRatio()).div(PERCENTAGE_100);
  }

  function convertDAIToDAIx(uint256 _amount) public view override returns (uint256) {
    return _amount.mul(PERCENTAGE_100).div(getDAIToDAIxRatio());
  }

  // TODO possible sandwich attack or allowance fluctuation
  function getClaimApprovalAmount(address user) external view override returns (uint256) {
    require(policyRegistry.isPolicyActive(user, address(this)), "PB: Policy is not active");

    return priceFeed.howManyBMIsInDAI(policyHolders[user].coverTokens.div(100));
  }

  function _submitClaimAndInitializeVoting(address claimer, bool appeal) internal {
    require(policyRegistry.isPolicyActive(claimer, address(this)), "PB: Policy is not active");

    claimVoting.initializeVoting(
      claimer,
      address(this),
      policyHolders[claimer].coverTokens,
      policyHolders[claimer].payedToProtocol,
      appeal
    );
  }

  function submitClaimAndInitializeVoting() external override {
    _submitClaimAndInitializeVoting(_msgSender(), false);
  }

  function submitAppealAndInitializeVoting() external override {
    _submitClaimAndInitializeVoting(_msgSender(), true);
  }

  function commitClaim(address claimer, uint256 claimAmount) 
    external 
    override 
    onlyClaimVoting
    updateBMIDAIXStakingReward
  {
    PolicyHolder storage holder = policyHolders[claimer];

    epochAmounts[holder.endEpochNumber] = epochAmounts[holder.endEpochNumber].sub(holder.coverTokens);
    totalLiquidity = totalLiquidity.sub(claimAmount);
    
    daiToken.transfer(claimer, claimAmount);
                    
    delete policyHolders[claimer];
    policyRegistry.removePolicy(claimer);
  }

  function buyPolicy(
    uint256 _epochsNumber,
    uint256 _coverTokens    
  ) external override withPremiumsDistribution updateBMIDAIXStakingReward {
    require(_coverTokens > 0, "PB: Cover is zero");
    require(_epochsNumber > 0, "PB: Epoch is zero");
    require(!policyRegistry.isPolicyActive(_msgSender(), address(this)),
      "PB: The holder already exists");
    require(!claimingRegistry.isClaimPending(claimingRegistry.claimIndex(_msgSender(), address(this))),
      "PB: This claim is pending");

    updateEpochsInfo();

    require(totalLiquidity >= totalCoverTokens.add(_coverTokens), "PB: Not enough liquidity");
    
    uint256 _totalSeconds = getTotalSecondsOfEpochs(_epochsNumber, currentEpochNumber);
    uint256 _endEpochNumber = currentEpochNumber.add(_epochsNumber.sub(1));

    uint256 _totalPrice = policyQuote.getQuote(_totalSeconds, _coverTokens, address(this));
    
    uint256 _reinsurancePrice = _totalPrice.mul(PROTOCOL_PERCENTAGE).div(PERCENTAGE_100);
    uint256 _price = _totalPrice.sub(_reinsurancePrice);

    policyHolders[_msgSender()] = PolicyHolder(
      _coverTokens, 
      currentEpochNumber,
      _endEpochNumber, 
      _totalPrice, 
      _reinsurancePrice
    );

    epochAmounts[_endEpochNumber] = epochAmounts[_endEpochNumber].add(_coverTokens);

    totalCoverTokens = totalCoverTokens.add(_coverTokens);

    daiToken.transferFrom(_msgSender(), reinsurancePoolAddress, _reinsurancePrice);
    daiToken.transferFrom(_msgSender(), address(this), _price);    

    _addPolicyPremiumToDistributions(_price, _epochsNumber);

    emit BuyPolicy(_msgSender(), _coverTokens, _price, totalCoverTokens);

    policyRegistry.addPolicy(_msgSender(), _coverTokens, _price, _totalSeconds);
  }

  function _addPolicyPremiumToDistributions(
    uint256 _distributedAmount, 
    uint256 _epochsNumber
  ) internal {
    uint256 distributionEpochs = _epochsNumber.mul(EPOCH_DURATION).div(PREMIUM_DISTRIBUTION_EPOCH);
    uint256 cappedDistributionEpochs = distributionEpochs.min(MAX_PREMIUM_DISTRIBUTION_EPOCHS);
    int256 distributedPerDay = int256(_distributedAmount.div(cappedDistributionEpochs));
    uint256 nextEpoch = getDistributionEpoch().add(1);

    premiumDistributionDeltas[nextEpoch] += distributedPerDay;
    premiumDistributionDeltas[nextEpoch.add(cappedDistributionEpochs)] -= distributedPerDay;
  }

  function _distributePremiums() internal {
    uint256 currentEpoch = getDistributionEpoch();
    uint256 lastEpoch = lastPremiumDistributionEpoch;

    if (currentEpoch > lastEpoch) {
      int256 currentDistribution = lastPremiumDistributionAmount;
      uint256 newTotalLiquidity = totalLiquidity;
      uint256 lastDistributionEpoch = currentEpoch.min(
        lastEpoch + MAX_PREMIUM_DISTRIBUTION_EPOCHS + 1
      );

      for (uint256 i = lastEpoch + 1; i <= lastDistributionEpoch; i++) {
        currentDistribution = currentDistribution + premiumDistributionDeltas[i];
        newTotalLiquidity = newTotalLiquidity.add(uint256(currentDistribution));
      }

      lastPremiumDistributionAmount = currentDistribution;
      lastPremiumDistributionEpoch = currentEpoch;
      totalLiquidity = newTotalLiquidity;
    }
  }

  function updateEpochsInfo() public override {
    (uint256 _lastEpochUpdate, uint256 _currentEpochNumber, uint256 _totalCoverTokens) = getUpdatedEpochsInfo();

    for (uint256 i = _lastEpochUpdate; i < _currentEpochNumber; i++) {
      delete epochAmounts[i];
    }

    currentEpochNumber = _currentEpochNumber;
    totalCoverTokens = _totalCoverTokens;
  }

  function getTotalSecondsOfEpochs(uint256 _epochs, uint256 _currentEpochNumber) 
    public 
    view 
    override 
    returns (uint256) 
  {
    uint256 _secondsToEndCurrentEpoch = 
      _currentEpochNumber.mul(EPOCH_DURATION).sub(block.timestamp.sub(epochStartTime));

    return _secondsToEndCurrentEpoch.add(_epochs.sub(1).mul(EPOCH_DURATION));
  }

  function getUpdatedEpochsInfo() 
    public 
    view 
    override 
    returns (uint256 lastEpochUpdate, uint256 newEpochNumber, uint256 newTotalCoverTokens) 
  {    
    uint256 _countOfPassedEpoch = block.timestamp.sub(epochStartTime).div(EPOCH_DURATION);

    newTotalCoverTokens = totalCoverTokens;
    lastEpochUpdate = currentEpochNumber;
    newEpochNumber = _countOfPassedEpoch.add(1);

    for (uint256 i = lastEpochUpdate; i < newEpochNumber; i++) {
      newTotalCoverTokens = newTotalCoverTokens.sub(epochAmounts[i]);      
    }
  }

  function addLiquidity(uint256 _liquidityAmount) external override {
    _addLiquidityFor(_msgSender(), _liquidityAmount, false);
  }

  function addLiquidityFromLM(
    address _liquidityHolderAddr, 
    uint256 _liquidityAmount
  ) onlyLiquidityMining external override {
    _addLiquidityFor(_liquidityHolderAddr, _liquidityAmount, true);
  }  

   function addLiquidityAndStake(
    uint256 _liquidityAmount,      
    uint256 _bmiDAIxAmount
  ) external override {
    require(convertDAIXtoDAI(_bmiDAIxAmount) <= _liquidityAmount, "PB: Wrong BMIDAIx amount");

    _addLiquidityFor(_msgSender(), _liquidityAmount, false);
    bmiDaiStaking.stakeDAIxFrom(_msgSender(), _bmiDAIxAmount);
  }

  function addLiquidityAndStakeWithPermit(
    uint256 _liquidityAmount,      
    uint256 _bmiDAIxAmount,    
    uint8 v,
    bytes32 r, 
    bytes32 s
  ) external override {
    require(convertDAIXtoDAI(_bmiDAIxAmount) <= _liquidityAmount, "PB: Wrong BMIDAIx amount");

    _addLiquidityFor(_msgSender(), _liquidityAmount, false);
    bmiDaiStaking.stakeDAIxFromWithPermit(_msgSender(), _bmiDAIxAmount, v, r, s);
  }

  function _addLiquidityFor(
    address _liquidityHolderAddr, 
    uint256 _liquidityAmount, 
    bool _isLM
  ) internal withPremiumsDistribution updateBMIDAIXStakingReward {
    require (_liquidityAmount > 0, "PB: Liquidity amount is zero");

    daiToken.transferFrom(_liquidityHolderAddr, address(this), _liquidityAmount);    
    
    uint256 _amountToMint = convertDAIToDAIx(_liquidityAmount);
    totalLiquidity = totalLiquidity.add(_liquidityAmount);
    _mint(_liquidityHolderAddr, _amountToMint);

    if (_isLM) {
      liquidityFromLM[_liquidityHolderAddr] = liquidityFromLM[_liquidityHolderAddr].add(_liquidityAmount);
    }

    liquidityRegistry.tryToAddPolicyBook(_liquidityHolderAddr, address(this));

    emit AddLiquidity(_liquidityHolderAddr, _liquidityAmount, totalLiquidity);
  }

  function getWithdrawalQueueSize() external view returns(uint256) {
    return withdrawalQueue.length();
  }

  function getWithdrawalQueue() external view override returns (address[] memory _resultArr) {
    uint256 _queueLength = withdrawalQueue.length();
    address _currentAddr = withdrawalQueue.head();

    _resultArr = new address[](_queueLength);

    for (uint256 i = 0; i < _queueLength; i++) {
      _resultArr[i] = _currentAddr;
      _currentAddr = withdrawalQueue.next(_currentAddr);
    }
  }

  function getIndexInQueue(address _userAddr) external view override returns (uint256) {
    return withdrawalQueue.indexOf(_userAddr, MAX_USERS_TO_UPDATE);
  }

  function isExitFromQueuePossible(address _userAddr) external view override returns (bool, uint256) {
    uint256 _currentIndex = withdrawalQueue.indexOf(_userAddr, MAX_USERS_TO_UPDATE);

    if (_currentIndex == MAX_USERS_TO_UPDATE) {
      return (false, MAX_USERS_TO_UPDATE);
    }

    uint256 _availableLiquidity = totalLiquidity.sub(totalCoverTokens);
    address _currentAddr = withdrawalQueue.head();

    for (uint256 i = 0; i <= _currentIndex; i++) {
      uint256 _tokensToWithdraw = withdrawalsInfo[_currentAddr].withdrawalAmount;
      uint256 _amountInDAI = convertDAIXtoDAI(_tokensToWithdraw);

      if (_availableLiquidity < _amountInDAI) {
        return (false, MAX_USERS_TO_UPDATE);
      }

      _availableLiquidity = _availableLiquidity.sub(_amountInDAI);
      _currentAddr = withdrawalQueue.next(_currentAddr);
    }

    return (true, _currentIndex);
  }

  function updateWithdrawalQueue(uint256 _lastIndexToUpdate) external override {
    uint256 _availableLiquidity = totalLiquidity.sub(totalCoverTokens);

    uint256 _usersToUpdateCount = withdrawalQueue.length().min(MAX_USERS_TO_UPDATE).min(_lastIndexToUpdate.add(1));
    uint256 _aggregatedQueueAmount = aggregatedQueueAmount;

    for (uint256 i = 0; i < _usersToUpdateCount; i++) {
      address _currentAddr = withdrawalQueue.head();
      uint256 _tokensToWithdraw = withdrawalsInfo[_currentAddr].withdrawalAmount;

      uint256 _amountInDAI = convertDAIXtoDAI(_tokensToWithdraw);

      if (_availableLiquidity < _amountInDAI) {
        break;
      }

      _withdrawLiquidity(_currentAddr, _tokensToWithdraw);
      _aggregatedQueueAmount = _aggregatedQueueAmount.sub(_tokensToWithdraw);
      _availableLiquidity = _availableLiquidity.sub(_amountInDAI);

      withdrawalQueue.removeFirst();
      delete withdrawalsInfo[_currentAddr];

      liquidityRegistry.tryToRemovePolicyBook(_msgSender(), address(this));
    }

    aggregatedQueueAmount = _aggregatedQueueAmount;
  }

  function leaveQueue() external override {
    require(getWithdrawalStatus(_msgSender()) == WithdrawalStatus.IN_QUEUE, "PB: User must be in queue");

    withdrawalQueue.remove(_msgSender());

    uint256 _currentWithdrawAmount = withdrawalsInfo[_msgSender()].withdrawalAmount;
    aggregatedQueueAmount = aggregatedQueueAmount.sub(_currentWithdrawAmount);
    _unlockTokens(_currentWithdrawAmount);
  }

  function getWithdrawalStatus(address _userAddr) public view override returns(WithdrawalStatus) {
    WithdrawalInfo storage _withdrawalInfo = withdrawalsInfo[_userAddr];

    if (_withdrawalInfo.readyToWithdrawDate == 0) {
      return WithdrawalStatus.NONE;
    }

    if (block.timestamp < _withdrawalInfo.readyToWithdrawDate) {
      return WithdrawalStatus.PENDING;
    }

    if (withdrawalQueue.contains(_userAddr)) {
      return WithdrawalStatus.IN_QUEUE;
    }

    if (block.timestamp >= _withdrawalInfo.readyToWithdrawDate.add(READY_TO_WITHDRAW_PERIOD)) {
      return WithdrawalStatus.EXPIRED;
    }

    return WithdrawalStatus.READY;
  }

  function requestWithdrawal(uint256 _tokensToWithdraw) external override {
    _requestWithdrawal(_tokensToWithdraw);
  }

  function requestWithdrawalWithPermit(
    uint256 _tokensToWithdraw,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external override {
    permit(_msgSender(), address(this), _tokensToWithdraw, MAX_INT, _v, _r, _s);
    _requestWithdrawal(_tokensToWithdraw);
  }

  function _requestWithdrawal(uint256 _tokensToWithdraw) internal withPremiumsDistribution {
    require(_tokensToWithdraw > 0, "PB: Amount to request must be greater than zero");

    WithdrawalStatus _status = getWithdrawalStatus(_msgSender());
    require(_status == WithdrawalStatus.NONE || _status == WithdrawalStatus.EXPIRED,
      "PB: Can't request withdrawal");

    uint256 _daiTokensToWithdraw = convertDAIXtoDAI(_tokensToWithdraw);
    uint256 _availableDaiBalance =
      convertDAIXtoDAI(balanceOf(_msgSender()).add(withdrawalsInfo[_msgSender()].withdrawalAmount));

    if (block.timestamp < liquidityMining.getEndLMTime().add(NEEDED_TIME_AFTER_LM)) {
      _availableDaiBalance = _availableDaiBalance.sub(liquidityFromLM[_msgSender()]);
    }

    require(_availableDaiBalance >= _daiTokensToWithdraw, "PB: Wrong announced amount");

    updateEpochsInfo();

    require(totalLiquidity >= totalCoverTokens.add(aggregatedQueueAmount).add(_daiTokensToWithdraw),
      "PB: Not enough available liquidity");

    _lockTokens(_msgSender(), _tokensToWithdraw);

    uint256 _readyToWithdrawDate = block.timestamp.add(WITHDRAWAL_PERIOD);
    withdrawalsInfo[_msgSender()] = WithdrawalInfo(_tokensToWithdraw, _readyToWithdrawDate);

    emit RequestWithdraw(_msgSender(), _tokensToWithdraw, _readyToWithdrawDate);
  }

  function unlockTokens() external override {
    require(getWithdrawalStatus(_msgSender()) == WithdrawalStatus.EXPIRED, "PB: Withdrawal status must be expired");

    _unlockTokens(withdrawalsInfo[_msgSender()].withdrawalAmount);
  }

  function _unlockTokens(uint256 _amountToUnlock) internal {
    this.transfer(_msgSender(), _amountToUnlock);
    delete withdrawalsInfo[_msgSender()];
  }

  function _lockTokens(address _userAddr, uint256 _neededTokensToLock) internal {
    uint256 _currentLockedTokens = withdrawalsInfo[_userAddr].withdrawalAmount;
    
    if (_currentLockedTokens > _neededTokensToLock) {
      this.transfer(_userAddr, _currentLockedTokens.sub(_neededTokensToLock));
    } else if (_currentLockedTokens < _neededTokensToLock) {
      this.transferFrom(_userAddr, address(this), _neededTokensToLock.sub(_currentLockedTokens));
    }
  }

  function withdrawLiquidity() external override withPremiumsDistribution {
    require(getWithdrawalStatus(_msgSender()) == WithdrawalStatus.READY,
      "PB: Withdrawal is not ready");

    uint256 _tokensToWithdraw = withdrawalsInfo[_msgSender()].withdrawalAmount;
    uint256 _availableLiquidity = totalLiquidity.sub(totalCoverTokens);

    if (withdrawalQueue.length() != 0) {
      withdrawalQueue.push(_msgSender());
      aggregatedQueueAmount = aggregatedQueueAmount.add(_tokensToWithdraw);
    } else if (_availableLiquidity < convertDAIXtoDAI(_tokensToWithdraw)) {
      uint256 _availableDAIxTokens = convertDAIToDAIx(_availableLiquidity);
      uint256 _currentWithdrawalAmount = _tokensToWithdraw.sub(_availableDAIxTokens);
      withdrawalsInfo[_msgSender()].withdrawalAmount = _currentWithdrawalAmount;

      aggregatedQueueAmount = aggregatedQueueAmount.add(_currentWithdrawalAmount);
      withdrawalQueue.push(_msgSender());

      _withdrawLiquidity(_msgSender(), _availableDAIxTokens);
    } else {
      _withdrawLiquidity(_msgSender(), _tokensToWithdraw);
      delete withdrawalsInfo[_msgSender()];

      liquidityRegistry.tryToRemovePolicyBook(_msgSender(), address(this));
    }
  }

  function _withdrawLiquidity(address _userAddr, uint256 _tokensToWithdraw) internal updateBMIDAIXStakingReward {
    uint256 _daiTokensToWithdraw = convertDAIXtoDAI(_tokensToWithdraw);
    daiToken.transfer(_userAddr, _daiTokensToWithdraw);    

    _burn(address(this), _tokensToWithdraw);

    totalLiquidity = totalLiquidity.sub(_daiTokensToWithdraw);

    emit WithdrawLiquidity(_userAddr, _daiTokensToWithdraw, totalLiquidity);
  }

  function triggerPremiumsDistribution() external {
    uint epochBefore = lastPremiumDistributionEpoch;
    _distributePremiums();

    emit DistributionManuallyTriggered(_msgSender(), lastPremiumDistributionEpoch.sub(epochBefore));
  }
  
  function userStats(address _user)
    external
    view
    override
    returns (
      PolicyHolder memory
    )
  {    
    if (policyRegistry.isPolicyActive(_user, address(this))) {
      return policyHolders[_user];
    }

    /// @dev returns an empty struct
    return policyHolders[address(0)];
  }

  function numberStats() 
    external
    view
    override
    returns (    
      uint256 _maxCapacities,
      uint256 _totalDaiLiquidity,
      uint256 _annualProfitYields      
    )
  {    
    return (
      totalLiquidity - totalCoverTokens, 
      totalLiquidity, 
      bmiDaiStaking.getPolicyBookAPY(address(this))
    );
  }

  function stats()
    external
    view
    override
    returns (
      string memory _name,
      address _insuredContract,
      IPolicyBookFabric.ContractType _contractType,
      bool _whitelisted
    )
  {    
    return (
      name(), 
      insuranceContractAddress,
      contractType,
      whitelisted
    );
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

import "../interfaces/IContractsRegistry.sol";

abstract contract AbstractDependant {
    /// @dev keccak256(AbstractDependant.setInjector(address)) - 1
    bytes32 private constant _INJECTOR_SLOT = 0xd6b8f2e074594ceb05d47c27386969754b6ad0c15e5eb8f691399cd0be980e76;

    modifier onlyInjectorOrZero() { 
        address _injector = injector();

        require(_injector == address(0) || _injector == msg.sender, 
            "Dependant: Not an injector");
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

library Queue {
    struct Node {
        address prev;
        address next;
    }

    struct UniqueAddressQueue {
        mapping(address => Node) queue;

        uint256 queueLength;

        address TAIL;
        address HEAD;
    }

    function push(UniqueAddressQueue storage baseQueue, address userAddr) internal returns (bool) {
        if (contains(baseQueue, userAddr)) {
            return false;
        }

        if (baseQueue.queueLength == 0) {
            baseQueue.queue[userAddr] = Node(address(0), address(0));
            baseQueue.TAIL = userAddr;
            baseQueue.HEAD = userAddr;
            baseQueue.queueLength++;

            return true;
        }

        baseQueue.queue[baseQueue.TAIL].next = userAddr;
        baseQueue.queue[userAddr] = Node(baseQueue.TAIL, address(0));
        baseQueue.TAIL = userAddr;

        baseQueue.queueLength++;

        return true;
    }

    function removeFirst(UniqueAddressQueue storage baseQueue) internal returns (bool) {
        if (baseQueue.queueLength > 0) {
            address prevHeadAddr = baseQueue.HEAD;
            address newHeadAddr = baseQueue.queue[prevHeadAddr].next;
            baseQueue.queue[newHeadAddr].prev = address(0);
            baseQueue.HEAD = newHeadAddr;
            baseQueue.queueLength--;

            if (baseQueue.queueLength == 0) {
                baseQueue.TAIL = newHeadAddr;
            }

            return true;
        }

        return false;
    }

    function removeLast(UniqueAddressQueue storage baseQueue) internal returns (bool) {
        if (baseQueue.queueLength > 0) {
            address prevTailAddr = baseQueue.TAIL;
            address newTailAddr = baseQueue.queue[prevTailAddr].prev;
            baseQueue.queue[newTailAddr].next = address(0);
            baseQueue.TAIL = newTailAddr;
            baseQueue.queueLength--;

            if (baseQueue.queueLength == 0) {
                baseQueue.HEAD = newTailAddr;
            }

            return true;
        }

        return false;
    }

    function remove(UniqueAddressQueue storage baseQueue, address addrToRemove) internal returns (bool) {
        if (!contains(baseQueue, addrToRemove)) {
            return false;
        }

        if (baseQueue.HEAD == addrToRemove) {
            return removeFirst(baseQueue);
        }

        if (baseQueue.TAIL == addrToRemove) {
            return removeLast(baseQueue);
        }

        address prevAddr = baseQueue.queue[addrToRemove].prev;
        address nextAddr = baseQueue.queue[addrToRemove].next;
        baseQueue.queue[prevAddr].next = nextAddr;
        baseQueue.queue[nextAddr].prev = prevAddr;
        baseQueue.queueLength--;

        return true;
    }

    function indexOf(
        UniqueAddressQueue storage baseQueue,
        address addr,
        uint256 limit
    ) internal view returns (uint256) {
        uint256 index = limit;
        uint256 size = baseQueue.queueLength < limit ? baseQueue.queueLength : limit;
        address currentAddr = baseQueue.HEAD;
        for (uint256 i = 0; i < size; i++) {
            if (currentAddr == addr) {
                index = i;
                break;
            }

            currentAddr = baseQueue.queue[currentAddr].next;
        }

        return index;
    }

    function next(UniqueAddressQueue storage baseQueue, address addr) internal view returns (address) {
        return baseQueue.queue[addr].next;
    }

    function at(UniqueAddressQueue storage baseQueue, uint256 index) internal view returns (address) {
        require(baseQueue.queueLength > index, "Queue: index out of bounds");

        address currentAddr = baseQueue.HEAD;
        for (uint256 i = 0; i < index; i++) {
            currentAddr = baseQueue.queue[currentAddr].next;
        }

        return currentAddr;
    }

    function contains(UniqueAddressQueue storage baseQueue, address addr) internal view returns (bool) {
        Node memory currentNode = baseQueue.queue[addr];

        if (baseQueue.HEAD != addr && currentNode.next == address(0) && currentNode.prev == address(0)) {
            return false;
        }

        return true;
    }

    function length(UniqueAddressQueue storage baseQueue) internal view returns (uint256) {
        return baseQueue.queueLength;
    }

    function head(UniqueAddressQueue storage baseQueue) internal view returns (address) {
        return baseQueue.HEAD;
    }

    function tail(UniqueAddressQueue storage baseQueue) internal view returns (address) {
        return baseQueue.TAIL;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface IBMIDAIStaking {
  struct StakingInfo {
    address policyBookAddress;

    uint256 stakingStartTime;
    uint256 stakingEndTime;

    uint256 stakedBmiDaiAmount;
    uint256 stakedDaiEquivalentAmount;
  }

  struct NFTsInfo {
    uint256 nftIndex;
    
    uint256 stakingStartTime;
    uint256 stakingEndTime;
    
    uint256 stakedBmiDaiAmount;
    uint256 reward;
  }

  function aggregateNFTs(address policyBookAddress, uint256[] calldata tokenIds) external;

  function stakeDAIx(uint256 amount, address policyBookAddress) external;

  function stakeDAIxWithPermit(
        uint256 bmiDaiAmount,          
        address policyBookAddress,
        uint8 v,
        bytes32 r, 
        bytes32 s
    ) external;

  function stakeDAIxFrom(address user, uint256 amount) external;

  function stakeDAIxFromWithPermit(
        address user,         
        uint256 bmiDaiAmount,
        uint8 v,
        bytes32 r, 
        bytes32 s
    ) external;

  function getPolicyBookAPY(address policyBookAddress) external view returns (uint256);

  function getBMIProfit(uint256 tokenId) external view returns (uint256);

  function getStakerBMIProfit(address staker, address policyBookAddress, uint256 offset, uint256 limit) 
    external
    view
    returns (uint256 totalProfit);

  function restakeBMIProfit(uint256 tokenId) external;

  function restakeStakerBMIProfit(address policyBookAddress) external;

  function withdrawBMIProfit(uint256 tokenID) external;

  function withdrawStakerBMIProfit(address policyBookAddress) external;

  function withdrawFundsWithProfit(uint256 tokenID) external;

  function withdrawStakerFundsWithProfit(address policyBookAddress) external;

  function stakingInfoByToken(uint256 tokenID) external view returns (StakingInfo memory);

  function totalStaked(address user, address policyBook) external view returns (uint256);

  function totalStaked(address user) external view returns (uint256);

  function balanceOf(address user) external view returns (uint256);
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
        uint256 withdrowalAmount;

        uint256 lockedBMIAmount;
        uint256 reinsuranceTokensAmount;

        uint256 votedAverageWithdrowalAmount;        

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

    /// @notice returns true if the user has unclaimed votes
    function canWithdraw(address user) external view returns (bool);

    /// @notice returns how many votes the user has
    function countVotes(address user) external view returns (uint256);  

    /// @notice returns status of the vote
    function voteStatus(uint256 index) external view returns (VoteStatus);

    /// @notice returns a list of claims that are votable for msg.sender
    function whatCanIVoteFor(uint256 offset, uint256 limit) 
        external
        returns (            
            uint256 _claimsCount,
            PublicClaimInfo[] memory _votablesInfo
        );

    /// @notice returns info list of ALL claims
    function allClaims(uint256 offset, uint256 limit)
        external
        view
        returns (
            uint256 _claimsCount,
            AllClaimInfo[] memory _allClaimsInfo
        ); 

    /// @notice returns info list of claims of msg.sender
    function myClaims(uint256 offset, uint256 limit) 
        external
        view 
        returns (
            uint256 _claimsCount,
            MyClaimInfo[] memory _myClaimsInfo
        );

    /// @notice returns info list of claims that are voted by msg.sender
    function myVotes(uint256 offset, uint256 limit) 
        external
        view
        returns (
            uint256 _votesCount,
            MyVoteInfo[] memory _myVotesInfo
        );

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
        bytes32[] calldata signatureOfVoteHashes
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
        uint256 index;

        address claimer;
        address policyBookAddress;        
        IPolicyBookFabric.ContractType contractType;

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
    function claimOfOwnerIndexAt(address claimer, uint256 orderIndex) external view returns (uint256);

    /// @notice returns pending claim index by its ordinal index
    function pendingClaimIndexAt(uint256 orderIndex) external view returns (uint256);

    /// @notice returns claim index by its ordinal index
    function claimIndexAt(uint256 orderIndex) external view returns (uint256);

    /// @notice returns current active claim index by policybook and claimer 
    function claimIndex(address claimer, address policyBookAddress) external view returns (uint256);

    /// @notice returns true if the claim is appealed
    function isClaimAppeal(uint256 index) external view returns (bool);

    /// @notice returns current status of a claim
    function policyStatus(address claimer, address policyBookAddress) external view returns (ClaimStatus);

    /// @notice returns current status of a claim
    function claimStatus(uint256 index) external view returns (ClaimStatus);

    /// @notice returns the claim owner
    function claimOwner(uint256 index) external view returns (address);

    /// @notice returns claim info by its index
    function claimInfo(uint256 index)
        external 
        view        
        returns (ClaimInfo memory _claimInfo);    

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

    function getPolicyBookImplementation() external view returns (address);

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

interface ILiquidityMining {
    struct TeamDetails {
      string teamName;
      address referralLink;
      uint256 membersNumber;
      uint256 totalStakedAmount;
    }

    struct MyTeamInfo {
      TeamDetails teamDetails;
      uint256 myStakedAmount;
    }

    struct UserInfo {
      string teamName;
      address userAddr;
      uint256 stakedAmount;
    }

    function startLiquidityMiningTime() external view returns (uint256);

    function createTeam(string calldata _teamName) external;

    function deleteTeam() external;

    function joinTheTeam(address _referralLink) external;

    function investDAI(uint256 _tokensAmount, address _policyBookAddr) external;

    function checkAvailableBMIReward(address _userAddr) external view returns (uint256);

    function getReward() external returns (uint256);

    function getEndLMTime() external view returns (uint256);

    function getAllTeamsDetails(uint256 _offset, uint256 _limit)
      external
      view
      returns (
        uint256 _size,
        TeamDetails[] memory _teamDetailsArr
      );

    function getMyTeamMembers(uint256 _offset, uint256 _limit)
      external
      view
      returns (
        uint256 _size,
        address[] memory _teamMembers,
        uint256[] memory _memberStakedAmount
      );

    function getAllUsersInfo(uint256 _offset, uint256 _limit)
      external
      view
      returns (
        uint256 _size,
        UserInfo[] memory _userInfos
      );

    function getMyTeamInfo() external view returns (MyTeamInfo memory);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.7.4;

interface ILiquidityRegistry {
  struct LiquidityInfo {
    address policyBookAddr;

    uint256 lockedAmount;
    uint256 availableAmount;
    uint256 stakedAmount;

    uint256 rewardsAmount;
    uint256 apy;
  }

  struct WithdrawalRequestInfo {
    address policyBookAddr;

    uint256 requestAmount;
    uint256 requestDAIAmount;
    uint256 availableLiquidity;

    uint256 readyToWithdrawDate;
    uint256 endWithdrawDate;
  }

  struct WithdrawalQueueInfo {
    address policyBookAddr;

    uint256 requestAmount;
    uint256 requestDAIAmount;

    bool isExitPossible;
    uint256 userIndex;
  }

  function tryToAddPolicyBook(address _userAddr, address _policyBookAddr) external;

  function tryToRemovePolicyBook(address _userAddr, address _policyBookAddr) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";

interface IPolicyBook {
  enum WithdrawalStatus {NONE, PENDING, READY, EXPIRED, IN_QUEUE}

  struct PolicyHolder {
    uint256 coverTokens;
    uint256 startEpochNumber;
    uint256 endEpochNumber;

    uint256 payed;
    uint256 payedToProtocol;
  }

  struct WithdrawalInfo {
    uint256 withdrawalAmount;
    uint256 readyToWithdrawDate;
  }

  function whitelisted() external view returns (bool);

  function EPOCH_DURATION() external view returns (uint256);

  function totalLiquidity() external view returns (uint256);

  function totalCoverTokens() external view returns (uint256);

  function epochStartTime() external view returns (uint256);

  function READY_TO_WITHDRAW_PERIOD() external view returns (uint256);

  function aggregatedQueueAmount() external view returns (uint256);

  function withdrawalsInfo(address _userAddr)
    external
    view
    returns (
      uint256 _withdrawalAmount,
      uint256 _readyToWithdrawDate
    );

  function whitelist(bool _whitelisted) external;

  // @TODO: should we let DAO to change contract address?
  /// @notice Returns address of contract this PolicyBook covers, access: ANY
  /// @return _contract is address of covered contract
  function insuranceContractAddress() external view returns (address _contract);

  /// @notice Returns type of contract this PolicyBook covers, access: ANY
  /// @return _type is type of contract
  function contractType() external view returns (IPolicyBookFabric.ContractType _type);    

  /// @notice get DAI equivalent
  function convertDAIXtoDAI(uint256 _amount) external view returns (uint256);    

  /// @notice get DAIx equivalent
  function convertDAIToDAIx(uint256 _amount) external view returns (uint256);

  function __PolicyBook_init(
    address _insuranceContract,
    IPolicyBookFabric.ContractType _contractType,    
    string calldata _description,
    string calldata _projectSymbol    
  ) external;

  function getWithdrawalStatus(address _userAddr) external view returns (WithdrawalStatus);

  /// @notice returns how many BMI tokens needs to approve in order to submit a claim
  function getClaimApprovalAmount(address user) external view returns (uint256);
  
  /// @notice submits new claim of the policy book
  function submitClaimAndInitializeVoting() external;

  /// @notice submits new appeal claim of the policy book
  function submitAppealAndInitializeVoting() external;

  /// @notice updates info on claim acceptance
  function commitClaim(address claimer, uint256 claimAmount) external;

  /// @notice Let user to buy policy by supplying DAI, access: ANY
  /// @param _durationSeconds is number of seconds to cover
  /// @param _coverTokens is number of tokens to cover  
  function buyPolicy(
    uint256 _durationSeconds,
    uint256 _coverTokens
  ) external;
  
  /// @notice converts epochs to seconds considering current epoch end time
  function getTotalSecondsOfEpochs(uint256 _epochs, uint256 _currentEpochNumber) 
    external 
    view 
    returns (uint256);

  /// @notice returns the future update
  function getUpdatedEpochsInfo() 
    external 
    view
    returns (
      uint256 lastEpochUpdate, 
      uint256 newEpochNumber, 
      uint256 newTotalCoverTokens
    ); 

  /// @notice Let user to add liquidity by supplying DAI, access: ANY
  /// @param _liqudityAmount is amount of DAI tokens to secure
  function addLiquidity(uint256 _liqudityAmount) external;

  /// @notice Let liquidityMining contract to add liqiudity for another user by supplying DAI, access: ONLY LM
  /// @param _liquidityHolderAddr is address of address to assign cover
  /// @param _liqudityAmount is amount of DAI tokens to secure
  function addLiquidityFromLM(address _liquidityHolderAddr, uint256 _liqudityAmount) external;

  function addLiquidityAndStake(uint256 _liquidityAmount, uint256 _bmiDAIxAmount) external;

  function addLiquidityAndStakeWithPermit(
    uint256 _liquidityAmount,      
    uint256 _bmiDAIxAmount,    
    uint8 v,
    bytes32 r, 
    bytes32 s
  ) external;

  function isExitFromQueuePossible(address _userAddr) external view returns (bool, uint256);

  function updateEpochsInfo() external;

  function updateWithdrawalQueue(uint256 _lastIndexToUpdate) external;

  function leaveQueue() external;

  function unlockTokens() external;

  function getWithdrawalQueue() external view returns (address[] memory _resultArr);

  function getIndexInQueue(address _userAddr) external view returns (uint256);

  function requestWithdrawal(uint256 _tokensToWithdraw) external;

  function requestWithdrawalWithPermit(
    uint256 _tokensToWithdraw,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external;

  /// @notice Let user to withdraw deposited liqiudity, access: ANY
  function withdrawLiquidity() external;  

  /// @notice Getting user stats, access: ANY 
  function userStats(address _user)
    external
    view    
    returns (
      PolicyHolder memory
    );

  /// @notice Getting number stats, access: ANY
  /// @return _maxCapacities is a max token amount that a user can buy
  /// @return _totalDaiLiquidity is PolicyBook's liquidity
  /// @return _annualProfitYields is its APY  
  function numberStats()
    external
    view
    returns (
      uint256 _maxCapacities,
      uint256 _totalDaiLiquidity,
      uint256 _annualProfitYields
    );

  /// @notice Getting stats, access: ANY
  /// @return _name is the name of PolicyBook
  /// @return _insuredContract is an addres of insured contract
  /// @return _contractType is a type of insured contract  
  /// @return _whitelisted is a state of whitelisting
  function stats()
    external
    view
    returns (
      string memory _name,
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
  /// @return _policyBook is address of created contract
  function create(
    address _contract,
    ContractType _contractType,
    string calldata _description,
    string calldata _projectSymbol
  ) external returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

interface IPolicyQuote {
  /// @notice Let user to calculate policy cost in DAI, access: ANY
  function getQuoteEpochs(
    uint256 _epochsNumber, 
    uint256 _tokens, 
    address _policyBookAddr
    ) external view returns (uint256);

  /// @notice Let user to calculate policy cost in DAI, access: ANY
  /// @param _durationSeconds is number of seconds to cover
  /// @param _tokens is number of tokens to cover
  /// @param _policyBookAddr is address of policy book
  /// @return _daiTokens is amount of DAI policy costs
  function getQuote(
    uint256 _durationSeconds,
    uint256 _tokens,
    address _policyBookAddr
  ) external view returns (uint256 _daiTokens);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "./IPolicyBookFabric.sol";
import "./IClaimingRegistry.sol";

interface IPolicyRegistry {
  struct PolicyInfo {
    uint256 coverAmount;
    uint256 premium;
    uint256 startTime;
    uint256 endTime;    
  }

  struct PolicyUserInfo {
    string name;
    address insuredContract;
    IPolicyBookFabric.ContractType contractType;

    uint256 coverTokens;
    uint256 startTime;
    uint256 endTime;

    uint256 payed;    
  }

  /// @notice Returns the number of the policy for the user, access: ANY
  /// @param _userAddr Policy holder address
  /// @return the number of police in the array
  function getPoliciesLength(address _userAddr) external view returns (uint256);

  /// @notice Shows whether the user has a policy, access: ANY
  /// @param _userAddr Policy holder address
  /// @param _policyBookAddr Address of policy book
  /// @return true if user has policy in specific policy book
  function policyExists(address _userAddr, address _policyBookAddr) external view returns (bool);

  /// @notice Returns information about current policy, access: ANY
  /// @param _userAddr Policy holder address
  /// @param _policyBookAddr Address of policy book
  /// @return true if user has active policy in specific policy book
  function isPolicyActive(address _userAddr, address _policyBookAddr) external view returns (bool);

  /// @notice returns current policy start time or zero
  function policyStartTime(address _userAddr, address _policyBookAddr) external view returns (uint256);

  /// @notice returns current policy end time or zero
  function policyEndTime(address _userAddr, address _policyBookAddr) external view returns (uint256);

  /// @notice Returns the array of the policy itself , access: ANY
  /// @param _userAddr Policy holder address
  /// @param _isActive If true, then returns an array with information about active policies, if false, about inactive
  /// @return _policiesCount is the number of police in the array
  /// @return _policyBooksArr is the array of policy books addresses
  /// @return _policies is the array of policies
  /// @return _policyStatuses parameter will show which button to display on the dashboard
  function getPoliciesInfo(address _userAddr, bool _isActive, uint256 _offset, uint256 _limit)
    external
    view 
    returns (
      uint256 _policiesCount,
      address[] memory _policyBooksArr,
      PolicyInfo[] memory _policies,
      IClaimingRegistry.ClaimStatus[] memory _policyStatuses
    );

  /// @notice Getting stats from users of policy books, access: ANY
  function getUsersInfo(address[] calldata _users, address[] calldata _policyBooks) 
    external
    view
    returns (
      PolicyUserInfo[] memory _stats
    );

  /// @notice Removes the policy book from the list, access: ONLY POLICY BOOKS
  /// @param _userAddr is the user's address  
  function removePolicy(address _userAddr) external;

  /// @notice Adds a new policy to the list , access: ONLY POLICY BOOKS
  /// @param _userAddr is the user's address 
  /// @param _coverAmount is the number of insured tokens
  /// @param _premium is the name of PolicyBook
  /// @param _durationDays is the number of days for which the insured 
  function addPolicy(
    address _userAddr,
    uint256 _coverAmount,
    uint256 _premium,
    uint256 _durationDays
  ) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

interface IRewardsGenerator {
    struct PolicyBookRewardInfo {
        uint256 rewardPerBlock; // includes precision
        uint256 rewardMultiplier; // includes 5 decimal places
        
        uint256 totalStaked;

        uint256 startStakeBlock;
        uint256 lastUpdateBlock;

        uint256 average; // includes 100 percentage
        uint256 toUpdateAverage; // includes 100 percentage
    }

    struct StakeRewardInfo {
        uint256 averageOnStake; // includes 100 percentage

        uint256 aggregatedReward;

        uint256 stakeAmount;
        uint256 stakeBlock;
    }

    /// @notice this function is called every time policybook's DAI to DAIx rate changes
    function updatePolicyBookShare(uint256 newRewardMultiplier) external;

    /// @notice aggregates specified nfts into a single one
    function aggregate(address policyBookAddress, uint256[] calldata nftIndexes, uint256 nftIndexTo) external;

    /// @notice informs generator of stake (rewards)
    function stake(address policyBookAddress, uint256 nftIndex, uint256 amount) external;

    /// @notice returns policybook's APY multiplied by 10**25
    function getPolicyBookAPY(address policyBookAddress) external view returns (uint256);

    /// @notice returns a reward of NFT
    function getReward(address policyBookAddress, uint256 nftIndex) external view returns (uint256);

    /// @notice informs generator of withdrawal (all funds)
    function withdrawFunds(address policyBookAddress, uint256 nftIndex) external returns (uint256);

    /// @notice informs generator of withdrawal (rewards)
    function withdrawReward(address policyBookAddress, uint256 nftIndex) external returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

interface IPriceFeed {
    function howManyBMIsInDAI(uint256 daiAmount) external view returns (uint256);

    function howManyDAIsInBMI(uint256 bmiAmount) external view returns (uint256);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

/**
 * COPIED FROM https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/tree/release-v3.4/contracts/drafts
 * @dev https://eips.ethereum.org/EIPS/eip-712[EIP 712] is a standard for hashing and signing of typed structured data.
 *
 * The encoding specified in the EIP is very generic, and such a generic implementation in Solidity is not feasible,
 * thus this contract does not implement the encoding itself. Protocols need to implement the type-specific encoding
 * they need in their contracts using a combination of `abi.encode` and `keccak256`.
 *
 * This contract implements the EIP 712 domain separator ({_domainSeparatorV4}) that is used as part of the encoding
 * scheme, and the final step of the encoding to obtain the message digest that is then signed via ECDSA
 * ({_hashTypedDataV4}).
 *
 * The implementation of the domain separator was designed to be as efficient as possible while still properly updating
 * the chain id to protect against replay attacks on an eventual fork of the chain.
 *
 * NOTE: This contract implements the version of the encoding known as "v4", as implemented by the JSON RPC method
 * https://docs.metamask.io/guide/signing-data.html[`eth_signTypedDataV4` in MetaMask].
 */
abstract contract EIP712Upgradeable is Initializable {
    /* solhint-disable var-name-mixedcase */
    bytes32 private _HASHED_NAME;
    bytes32 private _HASHED_VERSION;
    bytes32 private constant _TYPE_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /* solhint-enable var-name-mixedcase */

    /**
     * @dev Initializes the domain separator and parameter caches.
     *
     * The meaning of `name` and `version` is specified in
     * https://eips.ethereum.org/EIPS/eip-712#definition-of-domainseparator[EIP 712]:
     *
     * - `name`: the user readable name of the signing domain, i.e. the name of the DApp or the protocol.
     * - `version`: the current major version of the signing domain.
     *
     * NOTE: These parameters cannot be changed except through a xref:learn::upgrading-smart-contracts.adoc[smart
     * contract upgrade].
     */
    function __EIP712_init(string memory name, string memory version) internal initializer {
        __EIP712_init_unchained(name, version);
    }

    function __EIP712_init_unchained(string memory name, string memory version) internal initializer {
        bytes32 hashedName = keccak256(bytes(name));
        bytes32 hashedVersion = keccak256(bytes(version));
        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
    }

    /**
     * @dev Returns the domain separator for the current chain.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        return _buildDomainSeparator(_TYPE_HASH, _EIP712NameHash(), _EIP712VersionHash());
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 name, bytes32 version) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                typeHash,
                name,
                version,
                _getChainId(),
                address(this)
            )
        );
    }

    /**
     * @dev Given an already https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct[hashed struct], this
     * function returns the hash of the fully encoded EIP712 message for this domain.
     *
     * This hash can be used together with {ECDSA-recover} to obtain the signer of a message. For example:
     *
     * ```solidity
     * bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
     *     keccak256("Mail(address to,string contents)"),
     *     mailTo,
     *     keccak256(bytes(mailContents))
     * )));
     * address signer = ECDSA.recover(digest, signature);
     * ```
     */
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    function _getChainId() private view returns (uint256 chainId) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        // solhint-disable-next-line no-inline-assembly
        assembly {
            chainId := chainid()
        }
    }

    /**
     * @dev The hash of the name parameter for the EIP712 domain.
     *
     * NOTE: This function reads from storage by default, but can be redefined to return a constant value if gas costs
     * are a concern.
     */
    function _EIP712NameHash() internal virtual view returns (bytes32) {
        return _HASHED_NAME;
    }

    /**
     * @dev The hash of the version parameter for the EIP712 domain.
     *
     * NOTE: This function reads from storage by default, but can be redefined to return a constant value if gas costs
     * are a concern.
     */
    function _EIP712VersionHash() internal virtual view returns (bytes32) {
        return _HASHED_VERSION;
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.5 <0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./IERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

/**
 * COPIED FROM https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/tree/release-v3.4/contracts/drafts
 * @dev Implementation of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on `{IERC20-approve}`, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
abstract contract ERC20PermitUpgradeable is Initializable, ERC20Upgradeable, IERC20PermitUpgradeable, EIP712Upgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;

    mapping (address => CountersUpgradeable.Counter) private _nonces;

    // solhint-disable-next-line var-name-mixedcase
    bytes32 private _PERMIT_TYPEHASH;

    /**
     * @dev Initializes the {EIP712} domain separator using the `name` parameter, and setting `version` to `"1"`.
     *
     * It's a good idea to use the same `name` that is defined as the ERC20 token name.
     */
    function __ERC20Permit_init(string memory name) internal initializer {
        __Context_init_unchained();
        __EIP712_init_unchained(name, "1");
        __ERC20Permit_init_unchained(name);
    }

    function __ERC20Permit_init_unchained(string memory name) internal initializer {
        _PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    }

    /**
     * @dev See {IERC20Permit-permit}.
     */
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public virtual override {
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp <= deadline, "ERC20Permit: expired deadline");

        bytes32 structHash = keccak256(
            abi.encode(
                _PERMIT_TYPEHASH,
                owner,
                spender,
                value,
                _nonces[owner].current(),
                deadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = recover(hash, v, r, s);
        require(signer == owner, "ERC20Permit: invalid signature");

        _nonces[owner].increment();
        _approve(owner, spender, value);
    }

  /**
   * @dev Overload of {ECDSA-recover-bytes32-bytes-} that receives the `v`,
   * `r` and `s` signature fields separately.
   */
  function recover(
    bytes32 hash,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) internal pure returns (address) {
    // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
    // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
    // the valid range for s in (281): 0 < s < secp256k1n ÷ 2 + 1, and for v in (282): v ∈ {27, 28}. Most
    // signatures from current libraries generate a unique signature with an s-value in the lower half order.
    //
    // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
    // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
    // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
    // these malleable signatures as well.
    require(
      uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
      "ECDSA: invalid signature 's' value"
    );
    require(v == 27 || v == 28, "ECDSA: invalid signature 'v' value");

    // If the signature is valid (and not malleable), return the signer address
    address signer = ecrecover(hash, v, r, s);
    require(signer != address(0), "ECDSA: invalid signature");

    return signer;
  }

    /**
     * @dev See {IERC20Permit-nonces}.
     */
    function nonces(address owner) public view override returns (uint256) {
        return _nonces[owner].current();
    }

    /**
     * @dev See {IERC20Permit-DOMAIN_SEPARATOR}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }
    uint256[49] private __gap;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * COPIED FROM https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/tree/release-v3.4/contracts/drafts
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on `{IERC20-approve}`, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
interface IERC20PermitUpgradeable {
    /**
     * @dev Sets `value` as the allowance of `spender` over `owner`'s tokens,
     * given `owner`'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for `permit`, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;
import "../proxy/Initializable.sol";

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
abstract contract ContextUpgradeable is Initializable {
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
library SafeMathUpgradeable {
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

import "../../GSN/ContextUpgradeable.sol";
import "./IERC20Upgradeable.sol";
import "../../math/SafeMathUpgradeable.sol";
import "../../proxy/Initializable.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of ERC20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20Upgradeable is Initializable, ContextUpgradeable, IERC20Upgradeable {
    using SafeMathUpgradeable for uint256;

    mapping (address => uint256) private _balances;

    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    /**
     * @dev Sets the values for {name} and {symbol}, initializes {decimals} with
     * a default value of 18.
     *
     * To select a different value for {decimals}, use {_setupDecimals}.
     *
     * All three of these values are immutable: they can only be set once during
     * construction.
     */
    function __ERC20_init(string memory name_, string memory symbol_) internal initializer {
        __Context_init_unchained();
        __ERC20_init_unchained(name_, symbol_);
    }

    function __ERC20_init_unchained(string memory name_, string memory symbol_) internal initializer {
        _name = name_;
        _symbol = symbol_;
        _decimals = 18;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless {_setupDecimals} is
     * called.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view returns (uint8) {
        return _decimals;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        _balances[account] = _balances[account].sub(amount, "ERC20: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Sets {decimals} to a value other than the default one of 18.
     *
     * WARNING: This function should only be called from the constructor. Most
     * applications that interact with token contracts will not expect
     * {decimals} to ever change, and may work incorrectly if it does.
     */
    function _setupDecimals(uint8 decimals_) internal {
        _decimals = decimals_;
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
    uint256[44] private __gap;
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

import "../math/SafeMathUpgradeable.sol";

/**
 * @title Counters
 * @author Matt Condon (@shrugs)
 * @dev Provides counters that can only be incremented or decremented by one. This can be used e.g. to track the number
 * of elements in a mapping, issuing ERC721 ids, or counting request ids.
 *
 * Include with `using Counters for Counters.Counter;`
 * Since it is not possible to overflow a 256 bit integer with increments of one, `increment` can skip the {SafeMath}
 * overflow check, thereby saving gas. This does assume however correct usage, in that the underlying `_value` is never
 * directly accessed.
 */
library CountersUpgradeable {
    using SafeMathUpgradeable for uint256;

    struct Counter {
        // This variable should never be directly accessed by users of the library: interactions must be restricted to
        // the library's function. As of Solidity v0.5.2, this cannot be enforced, though there is a proposal to add
        // this feature: see https://github.com/ethereum/solidity/issues/4637
        uint256 _value; // default: 0
    }

    function current(Counter storage counter) internal view returns (uint256) {
        return counter._value;
    }

    function increment(Counter storage counter) internal {
        // The {SafeMath} overflow check can be skipped here, see the comment at the top
        counter._value += 1;
    }

    function decrement(Counter storage counter) internal {
        counter._value = counter._value.sub(1);
    }
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