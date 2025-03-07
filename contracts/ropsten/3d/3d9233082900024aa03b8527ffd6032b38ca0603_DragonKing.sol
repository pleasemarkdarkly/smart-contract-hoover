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


/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
  address public owner;


  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


  /**
   * @dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.
   */
  function Ownable() public {
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
   * @dev Allows the current owner to transfer control of the contract to a newOwner.
   * @param newOwner The address to transfer ownership to.
   */
  function transferOwnership(address newOwner) public onlyOwner {
    require(newOwner != address(0));
    OwnershipTransferred(owner, newOwner);
    owner = newOwner;
  }

}


/**
 * @title Destructible
 * @dev Base contract that can be destroyed by owner. All funds in contract will be sent to the owner.
 */
contract Destructible is Ownable {

  function Destructible() public payable { }

  /**
   * @dev Transfers the current balance to the owner and terminates the contract.
   */
  function destroy() onlyOwner public {
    selfdestruct(owner);
  }

  function destroyAndSend(address _recipient) onlyOwner public {
    selfdestruct(_recipient);
  }
}

contract DragonKingConfig {


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

}

interface Token {
  function transferFrom(address _from, address _to, uint256 _value) external returns (bool success);
  function transfer(address _to, uint256 _value) external returns (bool success);
  function balanceOf(address who) external view returns (uint256);
}


contract DragonKing is Destructible {

  struct Character {
    uint8 characterType;
    uint128 value;
    address owner;
    uint64 purchaseTimestamp;
  }

  DragonKingConfig  config = DragonKingConfig(0x5c3F04b8737165aa05C44c73654860525794B020);

  /** the neverdue token contract used to purchase protection from eruptions and fights */
  Token  neverdieToken = Token(0xEe7ACd6b0FB65eeBC11cF733fdC606619CF633D4);
  /** the teleport token contract used to send knights to the game scene */
  Token  teleportToken = Token(0x8A01Bc6A9358388588247127fF7BE21B281B36d4);

  /** the SKL token contract **/
  Token  sklToken = Token(0xD22d680d1fa045A07E8d335C1Bb815EbFC4D4e5E);
  /** the XP token contract **/
  Token  xperToken = Token(0x822afedd7d48ed1056247747c8ed6df7f02b50fc);
  

  /** array holding ids of the curret characters **/
  uint32[]  ids;
  /** the id to be given to the next character **/
  uint32  nextId = 1;
  /** non-existant character **/
  uint16  constant INVALID_CHARACTER_INDEX = ~uint16(0);

  /** the castle treasury **/
  uint128 public castleTreasury;
  /** the id of the oldest character **/
  uint32 public oldest;
  /** the character belonging to a given id **/
  mapping(uint32 => Character) characters;
  /** teleported knights **/
  mapping(uint32 => bool) teleported;

  /** constant used to signal that there is no King at the moment **/
  uint32 constant  noKing = ~uint32(0);

  /** total number of characters in the game **/
  uint16 public numCharacters;
  /** number of characters per type **/
  mapping(uint8 => uint16) numCharactersXType;

  /** timestampt of the last eruption event **/
  uint256 public lastEruptionTimestamp;
  /** timestampt of the last castle loot distribution **/
  uint256 public lastCastleLootDistributionTimestamp;

  /** character type range constants **/
  uint8  constant DRAGON_MIN_TYPE = 0;
  uint8  constant DRAGON_MAX_TYPE = 5;

  uint8  constant KNIGHT_MIN_TYPE = 6;
  uint8  constant KNIGHT_MAX_TYPE = 11;

  uint8  constant BALLOON_MIN_TYPE = 12;
  uint8  constant BALLOON_MAX_TYPE = 14;

  uint8  constant WIZARD_MIN_TYPE = 15;
  uint8  constant WIZARD_MAX_TYPE = 20;

  uint8  constant ARCHER_MIN_TYPE = 21;
  uint8  constant ARCHER_MAX_TYPE = 26;

  uint8  constant NUMBER_OF_LEVELS = 6;

  uint8  constant INVALID_CHARACTER_TYPE = 27;

  /** minimum amount of XPER and SKL to purchase wizards **/
  uint8  MIN_XPER_AMOUNT_TO_PURCHASE_WIZARD = 100;
  uint8  MIN_SKL_AMOUNT_TO_PURCHASE_WIZARD = 50;

  /** minimum amount of XPER and SKL to purchase archer **/
  uint8  MIN_XPER_AMOUNT_TO_PURCHASE_ARCHER = 10;
  uint8  MIN_SKL_AMOUNT_TO_PURCHASE_ARCHER = 5;

    /** knight cooldown. contains the timestamp of the earliest possible moment to start a fight */
  mapping(uint32 => uint)  cooldown;

    /** tells the number of times a character is protected */
  mapping(uint32 => uint8)  protection;

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


  /**
   * buys as many characters as possible with the transfered value of the given type
   * @param characterType the type of the character
   */
  function addCharacters(uint8 characterType) payable public {
    uint16 amount = uint16(msg.value / config.costs(characterType));
    uint16 nchars = numCharacters;
    if (characterType >= INVALID_CHARACTER_TYPE || msg.value < config.costs(characterType) || nchars + amount > config.maxCharacters()) revert();
    uint32 nid = nextId;
    //if type exists, enough ether was transferred and there are less than maxCharacters characters in the game
    if (characterType <= DRAGON_MAX_TYPE) {
      //dragons enter the game directly
      if (oldest == 0 || oldest == noKing)
        oldest = nid;
      for (uint8 i = 0; i < amount; i++) {
        addCharacter(nid + i, nchars + i);
        characters[nid + i] = Character(characterType, config.values(characterType), msg.sender, uint64(now));
      }
      numCharactersXType[characterType] += amount;
      numCharacters += amount;
    }
    else {
      uint256 amountSKL = sklToken.balanceOf(msg.sender);
      uint256 amountXPER = xperToken.balanceOf(msg.sender);
      if (characterType >= WIZARD_MIN_TYPE && characterType <= WIZARD_MAX_TYPE) {
        require( amountSKL >= MIN_SKL_AMOUNT_TO_PURCHASE_WIZARD && amountXPER >= MIN_XPER_AMOUNT_TO_PURCHASE_WIZARD, 
                "insufficient amount of SKL and XPER tokens"
               );
      }
      if (characterType >= ARCHER_MIN_TYPE && characterType <= ARCHER_MAX_TYPE) {
        require( amountSKL >= MIN_SKL_AMOUNT_TO_PURCHASE_ARCHER && amountXPER >= MIN_XPER_AMOUNT_TO_PURCHASE_ARCHER, 
                "insufficient amount of SKL and XPER tokens" 
               );
      }
      // to enter game knights, mages, and archers should be teleported later
      for (uint8 j = 0; j < amount; j++) {
        characters[nid + j] = Character(characterType, config.values(characterType), msg.sender, uint64(now));
      }
    }
    nextId = nid + amount;
    emit NewPurchase(msg.sender, characterType, amount, nid);
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
  function triggerVolcanoEruption() public {
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
    uint8 i = 0;
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
  function fight(uint32 characterID, uint16 characterIndex) public {
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
    cooldown[characterID] = now;
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
      protection[id] -= knockOffProtections;
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
    if (oldest == 0)
      findOldest();
    if (oldest != noKing) {
      //pay 10% to the oldest dragon
      characters[oldest].value += totalAmount / 10;
      amount  = totalAmount / 10 * 9;
    } else {
      amount  = totalAmount;
    }
    //distribute the rest according to their type
    uint128 valueSum;
    uint8 size = ARCHER_MAX_TYPE;
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
  * withdraw NDC and TPT tokens
  */
 /* function withdraw() public onlyOwner {
    uint256 ndcBalance = neverdieToken.balanceOf(this);
    assert(neverdieToken.transfer(owner, ndcBalance));
    uint256 tptBalance = teleportToken.balanceOf(this);
    assert(teleportToken.transfer(owner, tptBalance));
  }
*/

  /* @dev distributes castle loot among archers */
  function distributeCastleLoot() external {
    require(now >= lastCastleLootDistributionTimestamp + config.castleLootDistributionThreshold(),
            "not enough time passed since the last castle loot distribution");
    lastCastleLootDistributionTimestamp = now;
    uint128 luckFactor = uint128(generateRandomNumber(now) % 51);
    if (luckFactor < 5) {
      luckFactor = 5;
    }
    uint128 amount = castleTreasury * luckFactor / 100; 
    uint128 valueSum;
    uint128[] memory shares = new uint128[](NUMBER_OF_LEVELS);
    uint16 archersCount;
    uint32[] memory archers = new uint32[](numCharacters);

    uint8 cType;
    for (uint8 i = 0; i < ids.length; i++) {
      cType = characters[ids[i]].characterType; 
      if ((cType >= ARCHER_MIN_TYPE && cType <= ARCHER_MAX_TYPE) && (((uint64(now) - characters[ids[i]].purchaseTimestamp) / config.eruptionThreshold()) >= 7)) {
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
  function sellCharacter(uint32 characterId) public {
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
    uint32 id;
    uint256 price;
    if (msg.sender == address(teleportToken)) {
      id = toUint32(callData);
      price = config.teleportPrice();
      if (characters[id].characterType >= BALLOON_MIN_TYPE && characters[id].characterType <= WIZARD_MAX_TYPE) {
        price *= 2;
      }
      require(value >= price,
              "insufficinet amount of tokens to teleport this character");
      assert(teleportToken.transferFrom(sender, this, price));
      teleportCharacter(id);
    } else if (msg.sender == address(neverdieToken)) {
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
      if(cType <= KNIGHT_MAX_TYPE || (cType >= ARCHER_MIN_TYPE && cType <= ARCHER_MAX_TYPE)){
        lifePrice = ((cType % NUMBER_OF_LEVELS) + 1) * config.protectionPrice();
        max = 3;
      } else if (cType >= BALLOON_MIN_TYPE && cType <= BALLOON_MAX_TYPE) {
        lifePrice = (((cType+3) % NUMBER_OF_LEVELS) + 1) * config.protectionPrice() * 2;
        max = 6;
      } else if (cType >= WIZARD_MIN_TYPE && cType <= WIZARD_MAX_TYPE) {
        lifePrice = (((cType+3) % NUMBER_OF_LEVELS) + 1) * config.protectionPrice() * 2;
        max = 3;
      }

      price = 0;
      uint8 i = protection[id];
      for (i; i < max && value >= price + lifePrice * (i + 1); i++) {
        price += lifePrice * (i + 1);
      }
      assert(neverdieToken.transferFrom(sender, this, price));
      protectCharacter(id, i);
    } else {
      revert("Should be either from Neverdie or Teleport tokens");
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
  function getCharacterIndex(uint32 characterId) public returns(uint16) {
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
  function get10Characters(uint16 startIndex) public returns(uint32[10] characterIds, uint8[10] types, uint128[10] values, address[10] owners) {
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
}