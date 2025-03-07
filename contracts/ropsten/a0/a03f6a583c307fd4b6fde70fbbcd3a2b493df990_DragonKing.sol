/**
 * Note for the truffle testversion:
 * DragonKingTest inherits from DragonKing and adds one more function for testing the volcano from truffle.
 * For deployment on ropsten or mainnet, just deploy the DragonKing contract and remove this comment before verifying on
 * etherscan.
 * */

 /**
  * Dragonking is a blockchain game in which players may purchase dragons and knights of different levels and values.
  * Once every period of time the volcano erupts and wipes a few of them from the board. The value of the killed characters
  * gets distributed amongst all of the survivors. The dragon king receive a bigger share than the others.
  * In contrast to dragons, knights need to be teleported to the battlefield first with the use of teleport tokens.
  * Additionally, they may attack a dragon once per period.
  * Both character types can be protected from death up to three times.
  * Take a look at dragonking.io for more detailed information.
  * @author: Julia Altenried, Yuriy Kashnikov
  * */

pragma solidity ^0.4.24;


contract ERC20Basic {
  function totalSupply() public view returns (uint256);
  function balanceOf(address _who) public view returns (uint256);
  function transfer(address _to, uint256 _value) public returns (bool);
  event Transfer(address indexed from, address indexed to, uint256 value);
}

contract ERC20 is ERC20Basic {
  function allowance(address _owner, address _spender)
    public view returns (uint256);

  function transferFrom(address _from, address _to, uint256 _value)
    public returns (bool);

  function approve(address _spender, uint256 _value) public returns (bool);
  event Approval(
    address indexed owner,
    address indexed spender,
    uint256 value
  );
}



/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
  address public owner;


  event OwnershipRenounced(address indexed previousOwner);
  event OwnershipTransferred(
    address indexed previousOwner,
    address indexed newOwner
  );


  /**
   * @dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.
   */
  constructor() public {
    owner = msg.sender;
  }

  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  /**
   * @dev Allows the current owner to relinquish control of the contract.
   * @notice Renouncing to ownership will leave the contract without an owner.
   * It will not be possible to call the functions with the `onlyOwner`
   * modifier anymore.
   */
  function renounceOwnership() public onlyOwner {
    emit OwnershipRenounced(owner);
    owner = address(0);
  }

  /**
   * @dev Allows the current owner to transfer control of the contract to a newOwner.
   * @param _newOwner The address to transfer ownership to.
   */
  function transferOwnership(address _newOwner) public onlyOwner {
    _transferOwnership(_newOwner);
  }

  /**
   * @dev Transfers control of the contract to a newOwner.
   * @param _newOwner The address to transfer ownership to.
   */
  function _transferOwnership(address _newOwner) internal {
    require(_newOwner != address(0));
    emit OwnershipTransferred(owner, _newOwner);
    owner = _newOwner;
  }
}

/**
 * @title Destructible
 * @dev Base contract that can be destroyed by owner. All funds in contract will be sent to the owner.
 */
contract Destructible is Ownable {
  /**
   * @dev Transfers the current balance to the owner and terminates the contract.
   */
  function destroy() public onlyOwner {
    selfdestruct(owner);
  }

  function destroyAndSend(address _recipient) public onlyOwner {
    selfdestruct(_recipient);
  }
}

contract DragonKingConfig is Ownable {

  struct PurchaseRequirement {
    address[] tokens;
    uint256[] amounts;
  }

  /**
   * creates Configuration for the DragonKing game
   * tokens array should be in the following order:
      0    1    2    3     4    5    6    7     8
     [tpt, ndc, skl, xper, mag, stg, dex, luck, gift]
  */
  constructor(uint8 characterFee, uint8 eruptionThresholdInHours, uint8 percentageOfCharactersToKill, uint128[] charactersCosts, address[] tokens) public {
    fee = characterFee;
    for (uint8 i = 0; i < charactersCosts.length; i++) {
      costs.push(uint128(charactersCosts[i]) * 1 finney);
      values.push(costs[i] - costs[i] / 100 * fee);
    }
    eruptionThreshold = uint256(eruptionThresholdInHours) * 60 * 60; // convert to seconds
    castleLootDistributionThreshold = 1 days; // once per day
    percentageToKill = percentageOfCharactersToKill;
    maxCharacters = 600;
    teleportPrice = 1000000000000000000;
    protectionPrice = 1000000000000000000;
    luckThreshold = 4200;
    fightFactor = 4;
    giftTokenAmount = 1000000000000000000;
    giftToken = ERC20(tokens[8]);
    // purchase requirements
    // knights
    purchaseRequirements[7].tokens = [tokens[5]]; // 5 STG
    purchaseRequirements[7].amounts = [250];
    purchaseRequirements[8].tokens = [tokens[5]]; // 5 STG
    purchaseRequirements[8].amounts = [5*(10**2)];
    purchaseRequirements[9].tokens = [tokens[5]]; // 10 STG
    purchaseRequirements[9].amounts = [10*(10**2)];
    purchaseRequirements[10].tokens = [tokens[5]]; // 20 STG
    purchaseRequirements[10].amounts = [20*(10**2)];
    purchaseRequirements[11].tokens = [tokens[5]]; // 50 STG
    purchaseRequirements[11].amounts = [50*(10**2)];
    // wizards
    purchaseRequirements[15].tokens = [tokens[2], tokens[3]]; // 5 SKL % 10 XPER
    purchaseRequirements[15].amounts = [25*(10**17), 5*(10**2)];
    purchaseRequirements[16].tokens = [tokens[2], tokens[3], tokens[4]]; // 5 SKL & 10 XPER & 2.5 MAG
    purchaseRequirements[16].amounts = [5*(10**18), 10*(10**2), 250];
    purchaseRequirements[17].tokens = [tokens[2], tokens[3], tokens[4]]; // 10 SKL & 20 XPER & 5 MAG
    purchaseRequirements[17].amounts = [10*(10**18), 20*(10**2), 5*(10**2)];
    purchaseRequirements[18].tokens = [tokens[2], tokens[3], tokens[4]]; // 25 SKL & 50 XP & 10 MAG
    purchaseRequirements[18].amounts = [25*(10**18), 50*(10**2), 10*(10**2)];
    purchaseRequirements[19].tokens = [tokens[2], tokens[3], tokens[4]]; // 50 SKL & 100 XP & 20 MAG
    purchaseRequirements[19].amounts = [50*(10**18), 100*(10**2), 20*(10**2)]; 
    purchaseRequirements[20].tokens = [tokens[2], tokens[3], tokens[4]]; // 100 SKL & 200 XP & 50 MAG 
    purchaseRequirements[20].amounts = [100*(10**18), 200*(10**2), 50*(10**2)];
    // archers
    purchaseRequirements[21].tokens = [tokens[2], tokens[3]]; // 2.5 SKL & 5 XPER
    purchaseRequirements[21].amounts = [25*(10**17), 5*(10**2)];
    purchaseRequirements[22].tokens = [tokens[2], tokens[3], tokens[6]]; // 5 SKL & 10 XPER & 2.5 DEX
    purchaseRequirements[22].amounts = [5*(10**18), 10*(10**2), 250];
    purchaseRequirements[23].tokens = [tokens[2], tokens[3], tokens[6]]; // 10 SKL & 20 XPER & 5 DEX
    purchaseRequirements[23].amounts = [10*(10**18), 20*(10**2), 5*(10**2)];
    purchaseRequirements[24].tokens = [tokens[2], tokens[3], tokens[6]]; // 25 SKL & 50 XP & 10 DEX
    purchaseRequirements[24].amounts = [25*(10**18), 50*(10**2), 10*(10**2)];
    purchaseRequirements[25].tokens = [tokens[2], tokens[3], tokens[6]]; // 50 SKL & 100 XP & 20 DEX
    purchaseRequirements[25].amounts = [50*(10**18), 100*(10**2), 20*(10**2)]; 
    purchaseRequirements[26].tokens = [tokens[2], tokens[3], tokens[6]]; // 100 SKL & 200 XP & 50 DEX 
    purchaseRequirements[26].amounts = [100*(10**18), 200*(10**2), 50*(10**2)];
  }

  /** the Gift token contract **/
  ERC20 public giftToken;
  /** amount of gift tokens to send **/
  uint256 public giftTokenAmount;
  /** purchase requirements for each type of character **/
  PurchaseRequirement[30] purchaseRequirements; 
  /** the cost of each character type */
  uint128[] public costs;
  /** the value of each character type (cost - fee), so it&#39;s not necessary to compute it each time*/
  uint128[] public values;
  /** the fee to be paid each time an character is bought in percent*/
  uint8 fee;
  /** The maximum of characters allowed in the game */
  uint16 public maxCharacters;
  /** the amount of time that should pass since last eruption **/
  uint256 public eruptionThreshold;
  /** the amount of time that should pass ince last castle loot distribution **/
  uint256 public castleLootDistributionThreshold;
  /** how many characters to kill in %, e.g. 20 will stand for 20%, should be < 100 **/
  uint8 public percentageToKill;
  /* Cooldown threshold */
  uint256 public constant CooldownThreshold = 1 days;
  /** fight factor, used to compute extra probability in fight **/
  uint8 public fightFactor;

  /** the price for teleportation*/
  uint256 public teleportPrice;
  /** the price for protection */
  uint256 public protectionPrice;
  /** the luck threshold */
  uint256 public luckThreshold;

  function hasEnoughTokensToPurchase(address buyer, uint8 characterType) external returns (bool canBuy) {
    for (uint256 i = 0; i < purchaseRequirements[characterType].tokens.length; i++) {
      if (ERC20(purchaseRequirements[characterType].tokens[i]).balanceOf(buyer) < purchaseRequirements[characterType].amounts[i]) {
        return false;
      }
    }
    return true;
  }


  function setPurchaseRequirements(uint8 characterType, address[] tokens, uint256[] amounts) external {
    purchaseRequirements[characterType].tokens = tokens;
    purchaseRequirements[characterType].amounts = amounts;
  } 

  function getPurchaseRequirements(uint8 characterType) view external returns (address[] tokens, uint256[] amounts) {
    tokens = purchaseRequirements[characterType].tokens;
    amounts = purchaseRequirements[characterType].amounts;
  }

  /**
   * sets the prices of the character types
   * @param prices the prices in finney
   * */
  function setPrices(uint16[] prices) external onlyOwner {
    for (uint8 i = 0; i < prices.length; i++) {
      costs[i] = uint128(prices[i]) * 1 finney;
      values[i] = costs[i] - costs[i] / 100 * fee;
    }
  }

  /**
   * sets the eruption threshold
   * @param _value the threshold in seconds, e.g. 24 hours = 25*60*60
   * */
  function setEruptionThreshold(uint256 _value) external onlyOwner {
    eruptionThreshold = _value;
  }

  /**
   * sets the castle loot distribution threshold
   * @param _value the threshold in seconds, e.g. 24 hours = 25*60*60
   * */
  function setCastleLootDistributionThreshold(uint256 _value) external onlyOwner {
    castleLootDistributionThreshold = _value;
  }

  /**
   * sets the fee
   * @param _value for the fee, e.g. 3% = 3
   * */
  function setFee(uint8 _value) external onlyOwner {
    fee = _value;
  }

  /**
   * sets the percentage of characters to kill on eruption
   * @param _value the percentage, e.g. 10% = 10
   * */
  function setPercentageToKill(uint8 _value) external onlyOwner {
    percentageToKill = _value;
  }

  /**
   * sets the maximum amount of characters allowed to be present in the game
   * @param _value characters limit, e.g 600
   * */
  function setMaxCharacters(uint16 _value) external onlyOwner {
    maxCharacters = _value;
  }

  /**
   * sets the fight factor
   * @param _value fight factor, e.g 4
   * */
  function setFightFactor(uint8 _value) external onlyOwner {
    fightFactor = _value;
  }

  /**
   * sets the teleport price
   * @param _value base amount of TPT to transfer on teleport, e.g 10e18
   * */
  function setTeleportPrice(uint256 _value) external onlyOwner {
    teleportPrice = _value;
  }

  /**
   * sets the protection price
   * @param _value base amount of NDC to transfer on protection, e.g 10e18
   * */
  function setProtectionPrice(uint256 _value) external onlyOwner {
    protectionPrice = _value;
  }

  /**
   * sets the luck threshold
   * @param _value the minimum amount of luck tokens required for the second roll
   * */
  function setLuckThreshold(uint256 _value) external onlyOwner {
    luckThreshold = _value;
  }

  /**
   * sets the amount of tokens to gift threshold
   * @param _value new value of the amount to gift
   * */
  function setGiftTokenAmount(uint256 _value) {
    giftTokenAmount = _value;
  }

  /**
   * sets the gift token address
   * @param _value new gift token address
   * */
  function setGiftToken(address _value) {
    giftToken = ERC20(_value);
  }
}

contract DragonKing is Destructible {

  /**
   * @dev Throws if called by contract not a user 
   */
  modifier onlyUser() {
    require(msg.sender == tx.origin, 
            "contracts cannot execute this method"
           );
    _;
  }


  struct Character {
    uint8 characterType;
    uint128 value;
    address owner;
    uint64 purchaseTimestamp;
    uint8 fightCount;
  }

  DragonKingConfig public config;

  /** the neverdie token contract used to purchase protection from eruptions and fights */
  ERC20 neverdieToken;
  /** the teleport token contract used to send knights to the game scene */
  ERC20 teleportToken;
  /** the luck token contract **/
  ERC20 luckToken;
  /** the SKL token contract **/
  ERC20 sklToken;
  /** the XP token contract **/
  ERC20 xperToken;
  

  /** array holding ids of the curret characters **/
  uint32[] public ids;
  /** the id to be given to the next character **/
  uint32 public nextId;
  /** non-existant character **/
  uint16 public constant INVALID_CHARACTER_INDEX = ~uint16(0);

  /** the castle treasury **/
  uint128 public castleTreasury;
  /** the id of the oldest character **/
  uint32 public oldest;
  /** the character belonging to a given id **/
  mapping(uint32 => Character) characters;
  /** teleported knights **/
  mapping(uint32 => bool) teleported;

  /** constant used to signal that there is no King at the moment **/
  uint32 constant public noKing = ~uint32(0);

  /** total number of characters in the game **/
  uint16 public numCharacters;
  /** number of characters per type **/
  mapping(uint8 => uint16) public numCharactersXType;

  /** timestamp of the last eruption event **/
  uint256 public lastEruptionTimestamp;
  /** timestamp of the last castle loot distribution **/
  uint256 public lastCastleLootDistributionTimestamp;

  /** character type range constants **/
  uint8 public constant DRAGON_MIN_TYPE = 0;
  uint8 public constant DRAGON_MAX_TYPE = 5;

  uint8 public constant KNIGHT_MIN_TYPE = 6;
  uint8 public constant KNIGHT_MAX_TYPE = 11;

  uint8 public constant BALLOON_MIN_TYPE = 12;
  uint8 public constant BALLOON_MAX_TYPE = 14;

  uint8 public constant WIZARD_MIN_TYPE = 15;
  uint8 public constant WIZARD_MAX_TYPE = 20;

  uint8 public constant ARCHER_MIN_TYPE = 21;
  uint8 public constant ARCHER_MAX_TYPE = 26;

  uint8 public constant NUMBER_OF_LEVELS = 6;

  uint8 public constant INVALID_CHARACTER_TYPE = 27;

    /** knight cooldown. contains the timestamp of the earliest possible moment to start a fight */
  mapping(uint32 => uint) public cooldown;

    /** tells the number of times a character is protected */
  mapping(uint32 => uint8) public protection;

  // EVENTS

  /** is fired when new characters are purchased (who bought how many characters of which type?) */
  event NewPurchase(address player, uint8 characterType, uint16 amount, uint32 startId);
  /** is fired when a player leaves the game */
  event NewExit(address player, uint256 totalBalance, uint32[] removedCharacters);
  /** is fired when an eruption occurs */
  event NewEruption(uint32[] hitCharacters, uint128 value, uint128 gasCost);
  /** is fired when a single character is sold **/
  event NewSell(uint32 characterId, address player, uint256 value);
  /** is fired when a knight fights a dragon **/
  event NewFight(uint32 winnerID, uint32 loserID, uint256 value, uint16 probability, uint16 dice);
  /** is fired when a knight is teleported to the field **/
  event NewTeleport(uint32 characterId);
  /** is fired when a protection is purchased **/
  event NewProtection(uint32 characterId, uint8 lifes);
  /** is fired when a castle loot distribution occurs**/
  event NewDistributionCastleLoot(uint128 castleLoot);

  /* initializes the contract parameter */
  constructor(address tptAddress, address ndcAddress, address sklAddress, address xperAddress, address luckAddress, address _configAddress) public {
    nextId = 1;
    teleportToken = ERC20(tptAddress);
    neverdieToken = ERC20(ndcAddress);
    sklToken = ERC20(sklAddress);
    xperToken = ERC20(xperAddress);
    luckToken = ERC20(luckAddress);
    config = DragonKingConfig(_configAddress);
  }

  /** 
    * gifts one character
    * @param receiver gift character owner
    * @param characterType type of the character to create as a gift
    */
  function giftCharacter(address receiver, uint8 characterType) payable public onlyUser {
    _addCharacters(receiver, characterType);
    assert(config.giftToken().transfer(receiver, config.giftTokenAmount()));
  }

  /**
   * buys as many characters as possible with the transfered value of the given type
   * @param characterType the type of the character
   */
  function addCharacters(uint8 characterType) payable public onlyUser {
    _addCharacters(msg.sender, characterType);
  }

  function _addCharacters(address receiver, uint8 characterType) internal {
    uint16 amount = uint16(msg.value / config.costs(characterType));
    require(
      amount > 0,
      "insufficient amount of ether to purchase a given type of character");
    uint16 nchars = numCharacters;
    require(
      config.hasEnoughTokensToPurchase(receiver, characterType),
      "insufficinet amount of tokens to purchase a given type of character"
    );
    if (characterType >= INVALID_CHARACTER_TYPE || msg.value < config.costs(characterType) || nchars + amount > config.maxCharacters()) revert();
    uint32 nid = nextId;
    //if type exists, enough ether was transferred and there are less than maxCharacters characters in the game
    if (characterType <= DRAGON_MAX_TYPE) {
      //dragons enter the game directly
      if (oldest == 0 || oldest == noKing)
        oldest = nid;
      for (uint8 i = 0; i < amount; i++) {
        addCharacter(nid + i, nchars + i);
        characters[nid + i] = Character(characterType, config.values(characterType), receiver, uint64(now), 0);
      }
      numCharactersXType[characterType] += amount;
      numCharacters += amount;
    }
    else {
      // to enter game knights, mages, and archers should be teleported later
      for (uint8 j = 0; j < amount; j++) {
        characters[nid + j] = Character(characterType, config.values(characterType), receiver, uint64(now), 0);
      }
    }
    nextId = nid + amount;
    emit NewPurchase(receiver, characterType, amount, nid);
  }



  /**
   * adds a single dragon of the given type to the ids array, which is used to iterate over all characters
   * @param nId the id the character is about to receive
   * @param nchars the number of characters currently in the game
   */
  function addCharacter(uint32 nId, uint16 nchars) internal {
    if (nchars < ids.length)
      ids[nchars] = nId;
    else
      ids.push(nId);
  }

  /**
   * leave the game.
   * pays out the sender&#39;s balance and removes him and his characters from the game
   * */
  function exit() public {
    uint32[] memory removed = new uint32[](50);
    uint8 count;
    uint32 lastId;
    uint playerBalance;
    uint16 nchars = numCharacters;
    for (uint16 i = 0; i < nchars; i++) {
      if (characters[ids[i]].owner == msg.sender 
          && characters[ids[i]].purchaseTimestamp + 1 days < now
          && (characters[ids[i]].characterType < BALLOON_MIN_TYPE || characters[ids[i]].characterType > BALLOON_MAX_TYPE)) {
        //first delete all characters at the end of the array
        while (nchars > 0 
            && characters[ids[nchars - 1]].owner == msg.sender 
            && characters[ids[nchars - 1]].purchaseTimestamp + 1 days < now
            && (characters[ids[i]].characterType < BALLOON_MIN_TYPE || characters[ids[i]].characterType > BALLOON_MAX_TYPE)) {
          nchars--;
          lastId = ids[nchars];
          numCharactersXType[characters[lastId].characterType]--;
          playerBalance += characters[lastId].value;
          removed[count] = lastId;
          count++;
          if (lastId == oldest) oldest = 0;
          delete characters[lastId];
        }
        //replace the players character by the last one
        if (nchars > i + 1) {
          playerBalance += characters[ids[i]].value;
          removed[count] = ids[i];
          count++;
          nchars--;
          replaceCharacter(i, nchars);
        }
      }
    }
    numCharacters = nchars;
    emit NewExit(msg.sender, playerBalance, removed); //fire the event to notify the client
    msg.sender.transfer(playerBalance);
    if (oldest == 0)
      findOldest();
  }

  /**
   * Replaces the character with the given id with the last character in the array
   * @param index the index of the character in the id array
   * @param nchars the number of characters
   * */
  function replaceCharacter(uint16 index, uint16 nchars) internal {
    uint32 characterId = ids[index];
    numCharactersXType[characters[characterId].characterType]--;
    if (characterId == oldest) oldest = 0;
    delete characters[characterId];
    ids[index] = ids[nchars];
    delete ids[nchars];
  }

  /**
   * The volcano eruption can be triggered by anybody but only if enough time has passed since the last eription.
   * The volcano hits up to a certain percentage of characters, but at least one.
   * The percantage is specified in &#39;percentageToKill&#39;
   * */

  function triggerVolcanoEruption() public onlyUser {
    require(now >= lastEruptionTimestamp + config.eruptionThreshold(),
           "not enough time passed since last eruption");
    require(numCharacters > 0,
           "there are no characters in the game");
    lastEruptionTimestamp = now;
    uint128 pot;
    uint128 value;
    uint16 random;
    uint32 nextHitId;
    uint16 nchars = numCharacters;
    uint32 howmany = nchars * config.percentageToKill() / 100;
    uint128 neededGas = 80000 + 10000 * uint32(nchars);
    if(howmany == 0) howmany = 1;//hit at least 1
    uint32[] memory hitCharacters = new uint32[](howmany);
    bool[] memory alreadyHit = new bool[](nextId);
    uint16 i = 0;
    uint16 j = 0;
    while (i < howmany) {
      j++;
      random = uint16(generateRandomNumber(lastEruptionTimestamp + j) % nchars);
      nextHitId = ids[random];
      if (!alreadyHit[nextHitId]) {
        alreadyHit[nextHitId] = true;
        hitCharacters[i] = nextHitId;
        value = hitCharacter(random, nchars, 0);
        if (value > 0) {
          nchars--;
        }
        pot += value;
        i++;
      }
    }
    uint128 gasCost = uint128(neededGas * tx.gasprice);
    numCharacters = nchars;
    if (pot > gasCost){
      distribute(pot - gasCost); //distribute the pot minus the oraclize gas costs
      emit NewEruption(hitCharacters, pot - gasCost, gasCost);
    }
    else
      emit NewEruption(hitCharacters, 0, gasCost);
  }

  /**
   * Knight can attack a dragon.
   * Archer can attack only a balloon.
   * Dragon can attack wizards and archers.
   * Wizard can attack anyone, except balloon.
   * Balloon cannot attack.
   * The value of the loser is transfered to the winner.
   * @param characterID the ID of the knight to perfrom the attack
   * @param characterIndex the index of the knight in the ids-array. Just needed to save gas costs.
   *            In case it&#39;s unknown or incorrect, the index is looked up in the array.
   * */
  function fight(uint32 characterID, uint16 characterIndex) public onlyUser {
    if (characterID != ids[characterIndex])
      characterIndex = getCharacterIndex(characterID);
    Character storage character = characters[characterID];
    require(cooldown[characterID] + config.CooldownThreshold() <= now,
            "not enough time passed since the last fight of this character");
    require(character.owner == msg.sender,
            "only owner can initiate a fight for this character");

    uint8 ctype = character.characterType;
    require(ctype < BALLOON_MIN_TYPE || ctype > BALLOON_MAX_TYPE,
            "balloons cannot fight");

    uint16 adversaryIndex = getRandomAdversary(characterID, ctype);
    assert(adversaryIndex != INVALID_CHARACTER_INDEX);
    uint32 adversaryID = ids[adversaryIndex];

    Character storage adversary = characters[adversaryID];
    uint128 value;
    uint16 base_probability;
    uint16 dice = uint16(generateRandomNumber(characterID) % 100);
    if (luckToken.balanceOf(msg.sender) >= config.luckThreshold()) {
      base_probability = uint16(generateRandomNumber(dice) % 100);
      if (base_probability < dice) {
        dice = base_probability;
      }
      base_probability = 0;
    }
    uint256 characterPower = sklToken.balanceOf(character.owner) / 10**15 + xperToken.balanceOf(character.owner);
    uint256 adversaryPower = sklToken.balanceOf(adversary.owner) / 10**15 + xperToken.balanceOf(adversary.owner);
    
    if (character.value == adversary.value) {
        base_probability = 50;
      if (characterPower > adversaryPower) {
        base_probability += uint16(100 / config.fightFactor());
      } else if (adversaryPower > characterPower) {
        base_probability -= uint16(100 / config.fightFactor());
      }
    } else if (character.value > adversary.value) {
      base_probability = 100;
      if (adversaryPower > characterPower) {
        base_probability -= uint16((100 * adversary.value) / character.value / config.fightFactor());
      }
    } else if (characterPower > adversaryPower) {
        base_probability += uint16((100 * character.value) / adversary.value / config.fightFactor());
    }

    if (dice >= base_probability) {
      // adversary won
      if (adversary.characterType < BALLOON_MIN_TYPE || adversary.characterType > BALLOON_MAX_TYPE) {
        value = hitCharacter(characterIndex, numCharacters, adversary.characterType);
        if (value > 0) {
          numCharacters--;
        } else {
          cooldown[characterID] = now;
          if (characters[characterID].fightCount < 3) {
            characters[characterID].fightCount++;
          }
        }
        if (adversary.characterType >= ARCHER_MIN_TYPE && adversary.characterType <= ARCHER_MAX_TYPE) {
          castleTreasury += value;
        } else {
          adversary.value += value;
        }
        emit NewFight(adversaryID, characterID, value, base_probability, dice);
      } else {
        emit NewFight(adversaryID, characterID, 0, base_probability, dice); // balloons do not hit back
      }
    } else {
      // character won
      cooldown[characterID] = now;
      if (characters[characterID].fightCount < 3) {
        characters[characterID].fightCount++;
      }
      value = hitCharacter(adversaryIndex, numCharacters, character.characterType);
      if (value > 0) {
        numCharacters--;
      }
      if (character.characterType >= ARCHER_MIN_TYPE && character.characterType <= ARCHER_MAX_TYPE) {
        castleTreasury += value;
      } else {
        character.value += value;
      }
      if (oldest == 0) findOldest();
      emit NewFight(characterID, adversaryID, value, base_probability, dice);
    }
  }

  
  /*
  * @param characterType
  * @param adversaryType
  * @return whether adversaryType is a valid type of adversary for a given character
  */
  function isValidAdversary(uint8 characterType, uint8 adversaryType) pure returns (bool) {
    if (characterType >= KNIGHT_MIN_TYPE && characterType <= KNIGHT_MAX_TYPE) { // knight
      return (adversaryType <= DRAGON_MAX_TYPE);
    } else if (characterType >= WIZARD_MIN_TYPE && characterType <= WIZARD_MAX_TYPE) { // wizard
      return (adversaryType < BALLOON_MIN_TYPE || adversaryType > BALLOON_MAX_TYPE);
    } else if (characterType >= DRAGON_MIN_TYPE && characterType <= DRAGON_MAX_TYPE) { // dragon
      return (adversaryType >= WIZARD_MIN_TYPE);
    } else if (characterType >= ARCHER_MIN_TYPE && characterType <= ARCHER_MAX_TYPE) { // archer
      return ((adversaryType >= BALLOON_MIN_TYPE && adversaryType <= BALLOON_MAX_TYPE)
             || (adversaryType >= KNIGHT_MIN_TYPE && adversaryType <= KNIGHT_MAX_TYPE));
 
    }
    return false;
  }

  /**
   * pick a random adversary.
   * @param nonce a nonce to make sure there&#39;s not always the same adversary chosen in a single block.
   * @return the index of a random adversary character
   * */
  function getRandomAdversary(uint256 nonce, uint8 characterType) internal view returns(uint16) {
    uint16 randomIndex = uint16(generateRandomNumber(nonce) % numCharacters);
    // use 7, 11 or 13 as step size. scales for up to 1000 characters
    uint16 stepSize = numCharacters % 7 == 0 ? (numCharacters % 11 == 0 ? 13 : 11) : 7;
    uint16 i = randomIndex;
    //if the picked character is a knight or belongs to the sender, look at the character + stepSizes ahead in the array (modulo the total number)
    //will at some point return to the startingPoint if no character is suited
    do {
      if (isValidAdversary(characterType, characters[ids[i]].characterType) && characters[ids[i]].owner != msg.sender) {
        return i;
      }
      i = (i + stepSize) % numCharacters;
    } while (i != randomIndex);

    return INVALID_CHARACTER_INDEX;
  }


  /**
   * generate a random number.
   * @param nonce a nonce to make sure there&#39;s not always the same number returned in a single block.
   * @return the random number
   * */
  function generateRandomNumber(uint256 nonce) internal view returns(uint) {
    return uint(keccak256(block.blockhash(block.number - 1), now, numCharacters, nonce));
  }

	/**
   * Hits the character of the given type at the given index.
   * Wizards can knock off two protections. Other characters can do only one.
   * @param index the index of the character
   * @param nchars the number of characters
   * @return the value gained from hitting the characters (zero is the character was protected)
   * */
  function hitCharacter(uint16 index, uint16 nchars, uint8 characterType) internal returns(uint128 characterValue) {
    uint32 id = ids[index];
    uint8 knockOffProtections = 1;
    if (characterType >= WIZARD_MIN_TYPE && characterType <= WIZARD_MAX_TYPE) {
      knockOffProtections = 2;
    }
    if (protection[id] >= knockOffProtections) {
      protection[id] = protection[id] - knockOffProtections;
      return 0;
    }
    characterValue = characters[ids[index]].value;
    nchars--;
    replaceCharacter(index, nchars);
  }

  /**
   * finds the oldest character
   * */
  function findOldest() public {
    uint32 newOldest = noKing;
    for (uint16 i = 0; i < numCharacters; i++) {
      if (ids[i] < newOldest && characters[ids[i]].characterType <= DRAGON_MAX_TYPE)
        newOldest = ids[i];
    }
    oldest = newOldest;
  }

  /**
  * distributes the given amount among the surviving characters
  * @param totalAmount nthe amount to distribute
  */
  function distribute(uint128 totalAmount) internal {
    uint128 amount;
    castleTreasury += totalAmount / 20; //5% into castle treasury
    if (oldest == 0)
      findOldest();
    if (oldest != noKing) {
      //pay 10% to the oldest dragon
      characters[oldest].value += totalAmount / 10;
      amount  = totalAmount / 100 * 85;
    } else {
      amount  = totalAmount / 100 * 95;
    }
    //distribute the rest according to their type
    uint128 valueSum;
    uint8 size = ARCHER_MAX_TYPE + 1;
    uint128[] memory shares = new uint128[](size);
    for (uint8 v = 0; v < size; v++) {
      if ((v < BALLOON_MIN_TYPE || v > BALLOON_MAX_TYPE) && numCharactersXType[v] > 0) {
           valueSum += config.values(v);
      }
    }
    for (uint8 m = 0; m < size; m++) {
      if ((v < BALLOON_MIN_TYPE || v > BALLOON_MAX_TYPE) && numCharactersXType[m] > 0) {
        shares[m] = amount * config.values(m) / valueSum / numCharactersXType[m];
      }
    }
    uint8 cType;
    for (uint16 i = 0; i < numCharacters; i++) {
      cType = characters[ids[i]].characterType;
      if (cType < BALLOON_MIN_TYPE || cType > BALLOON_MAX_TYPE)
        characters[ids[i]].value += shares[characters[ids[i]].characterType];
    }
  }

  /**
   * allows the owner to collect the accumulated fees
   * sends the given amount to the owner&#39;s address if the amount does not exceed the
   * fees (cannot touch the players&#39; balances) minus 100 finney (ensure that oraclize fees can be paid)
   * @param amount the amount to be collected
   * */
  function collectFees(uint128 amount) public onlyOwner {
    uint collectedFees = getFees();
    if (amount + 100 finney < collectedFees) {
      owner.transfer(amount);
    }
  }

  /**
  * withdraw NDC and TPT tokens
  */
  function withdraw() public onlyOwner {
    uint256 ndcBalance = neverdieToken.balanceOf(this);
    if(ndcBalance > 0)
      assert(neverdieToken.transfer(owner, ndcBalance));
    uint256 tptBalance = teleportToken.balanceOf(this);
    if(tptBalance > 0)
      assert(teleportToken.transfer(owner, tptBalance));
  }

  /**
   * pays out the players.
   * */
  function payOut() public onlyOwner {
    for (uint16 i = 0; i < numCharacters; i++) {
      characters[ids[i]].owner.transfer(characters[ids[i]].value);
      delete characters[ids[i]];
    }
    delete ids;
    numCharacters = 0;
  }

  /**
   * pays out the players and kills the game.
   * */
  function stop() public onlyOwner {
    withdraw();
    payOut();
    destroy();
  }

  function generateLuckFactor(uint128 nonce) internal view returns(uint128) {
    uint128 sum = 0;
    uint128 inc = 1;
    for (uint128 i = 49; i >= 5; i--) {
      if (sum > nonce) {
          return i+2;
      }
      sum += inc;
      if (i != 40 && i != 8) {
          inc += 1;
      }
    }
    return 5;
  }

  /* @dev distributes castle loot among archers */
  function distributeCastleLoot() external onlyUser {
    require(now >= lastCastleLootDistributionTimestamp + config.castleLootDistributionThreshold(),
            "not enough time passed since the last castle loot distribution");
    lastCastleLootDistributionTimestamp = now;
    uint128 luckFactor = generateLuckFactor(uint128(now % 1000));
    if (luckFactor < 5) {
      luckFactor = 5;
    }
    uint128 amount = castleTreasury * luckFactor / 100; 
    uint128 valueSum;
    uint128[] memory shares = new uint128[](NUMBER_OF_LEVELS);
    uint16 archersCount;
    uint32[] memory archers = new uint32[](getNumArchers());

    uint8 cType;
    for (uint i = 0; i < numCharacters; i++) {
      cType = characters[ids[i]].characterType; 
      if ((cType >= ARCHER_MIN_TYPE && cType <= ARCHER_MAX_TYPE) 
        && (characters[ids[i]].fightCount >= 3)
        && (now - characters[ids[i]].purchaseTimestamp >= 7 days)) {
        valueSum += config.values(cType);
        archers[archersCount] = ids[i];
        archersCount++;
      }
    }

    if (valueSum > 0) {
      for (uint8 j = 0; j < NUMBER_OF_LEVELS; j++) {
          shares[j] = amount * config.values(ARCHER_MIN_TYPE + j) / valueSum;
      }

      for (uint16 k = 0; k < archersCount; k++) {
        characters[archers[k]].value += shares[characters[archers[k]].characterType - ARCHER_MIN_TYPE];
      }
      castleTreasury -= amount;
      emit NewDistributionCastleLoot(amount);
    } else {
      emit NewDistributionCastleLoot(0);
    }
  }

  /**
   * sell the character of the given id
   * throws an exception in case of a knight not yet teleported to the game
   * @param characterId the id of the character
   * */
  function sellCharacter(uint32 characterId) public onlyUser {
    require(msg.sender == characters[characterId].owner,
            "only owners can sell their characters");
    require(characters[characterId].characterType < BALLOON_MIN_TYPE || characters[characterId].characterType > BALLOON_MAX_TYPE,
            "balloons are not sellable");
    require(characters[characterId].purchaseTimestamp + 1 days < now,
            "character can be sold only 1 day after the purchase");
    uint128 val = characters[characterId].value;
    numCharacters--;
    replaceCharacter(getCharacterIndex(characterId), numCharacters);
    msg.sender.transfer(val);
    if (oldest == 0)
      findOldest();
    emit NewSell(characterId, msg.sender, val);
  }

  /**
   * receive approval to spend some tokens.
   * used for teleport and protection.
   * @param sender the sender address
   * @param value the transferred value
   * @param tokenContract the address of the token contract
   * @param callData the data passed by the token contract
   * */
  function receiveApproval(address sender, uint256 value, address tokenContract, bytes callData) public {
    require(tokenContract == address(teleportToken), "everything is paid with teleport tokens");
    bool forProtection = secondToUint32(callData) == 1 ? true : false;
    uint32 id;
    uint256 price;
    if (!forProtection) {
      id = toUint32(callData);
      price = config.teleportPrice();
      if (characters[id].characterType >= BALLOON_MIN_TYPE && characters[id].characterType <= WIZARD_MAX_TYPE) {
        price *= 2;
      }
      require(value >= price,
              "insufficinet amount of tokens to teleport this character");
      assert(teleportToken.transferFrom(sender, this, price));
      teleportCharacter(id);
    } else {
      id = toUint32(callData);
      // user can purchase extra lifes only right after character purchaes
      // in other words, user value should be equal the initial value
      uint8 cType = characters[id].characterType;
      require(characters[id].value == config.values(cType),
              "protection could be bought only before the first fight and before the first volcano eruption");

      // calc how many lifes user can actually buy
      // the formula is the following:

      uint256 lifePrice;
      uint8 max;
      if(cType <= KNIGHT_MAX_TYPE ){
        lifePrice = ((cType % NUMBER_OF_LEVELS) + 1) * config.protectionPrice();
        max = 3;
      } else if (cType >= BALLOON_MIN_TYPE && cType <= BALLOON_MAX_TYPE) {
        lifePrice = (((cType+3) % NUMBER_OF_LEVELS) + 1) * config.protectionPrice() * 2;
        max = 6;
      } else if (cType >= WIZARD_MIN_TYPE && cType <= WIZARD_MAX_TYPE) {
        lifePrice = (((cType+3) % NUMBER_OF_LEVELS) + 1) * config.protectionPrice() * 2;
        max = 3;
      } else if (cType >= ARCHER_MIN_TYPE && cType <= ARCHER_MAX_TYPE) {
        lifePrice = (((cType+3) % NUMBER_OF_LEVELS) + 1) * config.protectionPrice();
        max = 3;
      }

      price = 0;
      uint8 i = protection[id];
      for (i; i < max && value >= price + lifePrice * (i + 1); i++) {
        price += lifePrice * (i + 1);
      }
      assert(teleportToken.transferFrom(sender, this, price));
      protectCharacter(id, i);
    } 
  }

  /**
   * Knights, balloons, wizards, and archers are only entering the game completely, when they are teleported to the scene
   * @param id the character id
   * */
  function teleportCharacter(uint32 id) internal {
    // ensure we do not teleport twice
    require(teleported[id] == false,
           "already teleported");
    teleported[id] = true;
    Character storage character = characters[id];
    require(character.characterType > DRAGON_MAX_TYPE,
           "dragons do not need to be teleported"); //this also makes calls with non-existent ids fail
    addCharacter(id, numCharacters);
    numCharacters++;
    numCharactersXType[character.characterType]++;
    emit NewTeleport(id);
  }

  /**
   * adds protection to a character
   * @param id the character id
   * @param lifes the number of protections
   * */
  function protectCharacter(uint32 id, uint8 lifes) internal {
    protection[id] = lifes;
    emit NewProtection(id, lifes);
  }


  /****************** GETTERS *************************/

  /**
   * returns the character of the given id
   * @param characterId the character id
   * @return the type, value and owner of the character
   * */
  function getCharacter(uint32 characterId) public view returns(uint8, uint128, address) {
    return (characters[characterId].characterType, characters[characterId].value, characters[characterId].owner);
  }

  /**
   * returns the index of a character of the given id
   * @param characterId the character id
   * @return the character id
   * */
  function getCharacterIndex(uint32 characterId) view public returns(uint16) {
    for (uint16 i = 0; i < ids.length; i++) {
      if (ids[i] == characterId) {
        return i;
      }
    }
    revert();
  }

  /**
   * returns 10 characters starting from a certain indey
   * @param startIndex the index to start from
   * @return 4 arrays containing the ids, types, values and owners of the characters
   * */
  function get10Characters(uint16 startIndex) view public returns(uint32[10] characterIds, uint8[10] types, uint128[10] values, address[10] owners) {
    uint32 endIndex = startIndex + 10 > numCharacters ? numCharacters : startIndex + 10;
    uint8 j = 0;
    uint32 id;
    for (uint16 i = startIndex; i < endIndex; i++) {
      id = ids[i];
      characterIds[j] = id;
      types[j] = characters[id].characterType;
      values[j] = characters[id].value;
      owners[j] = characters[id].owner;
      j++;
    }

  }

  /**
   * returns the number of dragons in the game
   * @return the number of dragons
   * */
  function getNumDragons() view public returns(uint16 numDragons) {
    for (uint8 i = DRAGON_MIN_TYPE; i <= DRAGON_MAX_TYPE; i++)
      numDragons += numCharactersXType[i];
  }

  /**
   * returns the number of wizards in the game
   * @return the number of wizards
   * */
  function getNumWizards() view public returns(uint16 numWizards) {
    for (uint8 i = WIZARD_MIN_TYPE; i <= WIZARD_MAX_TYPE; i++)
      numWizards += numCharactersXType[i];
  }
  /**
   * returns the number of archers in the game
   * @return the number of archers
   * */
  function getNumArchers() view public returns(uint16 numArchers) {
    for (uint8 i = ARCHER_MIN_TYPE; i <= ARCHER_MAX_TYPE; i++)
      numArchers += numCharactersXType[i];
  }

  /**
   * returns the number of knights in the game
   * @return the number of knights
   * */
  function getNumKnights() view public returns(uint16 numKnights) {
    for (uint8 i = KNIGHT_MIN_TYPE; i <= KNIGHT_MAX_TYPE; i++)
      numKnights += numCharactersXType[i];
  }

  /**
   * @return the accumulated fees
   * */
  function getFees() view public returns(uint) {
    uint reserved = 0;
    for (uint16 j = 0; j < numCharacters; j++)
      reserved += characters[ids[j]].value;
    return address(this).balance - reserved;
  }


  /************* HELPERS ****************/

  /**
   * only works for bytes of length < 32
   * @param b the byte input
   * @return the uint
   * */
  function toUint32(bytes b) internal pure returns(uint32) {
    bytes32 newB;
    assembly {
      newB: = mload(0xa0)
    }
    return uint32(newB);
  }
  
  function secondToUint32(bytes b) internal pure returns(uint32){
    bytes32 newB;
    assembly {
      newB: = mload(0xc0)
    }
    return uint32(newB);
  }
}

contract DragonKingTest is DragonKing {
  /* Test contract can trigger volcano eruption any time (eruptionThreshold=0), harming 10% of all characters. It will have 5% fee and a given set of costs. */
  function DragonKingTest(address tpt, address ndc, address skl, address xper, address luck, address cfg) DragonKing(tpt, ndc, skl, xper, luck, cfg) public {
  }

  function getCosts() public pure returns(uint16[] costs) {
    costs = new uint16[](6);
    costs[0] = uint16(10);
    costs[1] = uint16(20);
    costs[2] = uint16(50);
    costs[3] = uint16(100);
    costs[4] = uint16(500);
    costs[5] = uint16(1000);
  }

  function getBalloonCosts() public pure returns(uint16[] costs) {
    costs = new uint16[](3);
    costs[0] = uint16(100);
    costs[1] = uint16(500);
    costs[2] = uint16(1000);
  }

  /** test random dragon selection **/
  function testGetRandomDragon(uint256 nonce) public view returns(uint16) {
    return getRandomAdversary(nonce, KNIGHT_MIN_TYPE);
  }

  function random(uint128 nonce) public view returns(uint128) {
    return generateLuckFactor(nonce);
  }

}