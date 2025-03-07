// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "./interfaces/ILandRegistration.sol"; 
import "./interfaces/IManagementCompany.sol";
import "./interfaces/ILoanOriginator.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract LandRegistration is ILandRegistration {
    using SafeMath for uint256;

    address public  MCBoard;            // MCBoard Contract address

    // developer related
    uint    public  nextDeveloperID;     // next developer ID
    uint[]  public  activeDeveloperIDs;  // current active dev ID array
    mapping(uint => Developer)  public  getDeveloperByID;        // using developer id -> developer info struct
    mapping(uint => uint)       public  indexOfDeveloper;        // using developer id -> get corresponding index of activeDeveloperIDs
    mapping(uint => bool)       public override isDeveloperIDValid;      // using developer id -> developer valid or not

    // land related
    uint    public  nextLandID;          // next land ID
    uint[]  public  activeLandIDs;       // current active land ID array
    mapping(uint => Land) public  getLandByID;       // using land ID -> land info struct
    mapping(uint => uint) public  indexOfLand;       // using land ID -> get corresponding index of activeLandIDs
    mapping(uint => bool) public override isLandIDValid;     // using landID -> land valid or not

    // CMP related
    // uint    public  nextCMP;         // CMP index
    // uint[]  public  activeCMPIDs;    // since CMP has no valid, this is from [1,nextCMP]
    // mapping(uint => CommitmentMortgagePackage) public  CMPs;    // CMP notes mapping

    // only MC admins can procced
    modifier onlyAdmins {
        require(IManagementCompany(MCBoard).isMCAdmin(msg.sender) == true, "Only admins can call this");
         _;
    }

    // only MC admins can procced
    modifier onlyLOSC {
        require(msg.sender == IManagementCompany(MCBoard).LOSCAddress(), "Only LOSC can call this");
         _;
    }

    constructor(
        address _MCBoard    // MC_Contract Address
    ) public {
        MCBoard = _MCBoard;
        // set both active array first element to 0, so deleted developers & lands can refer to this
        activeDeveloperIDs.push(0); 
        activeLandIDs.push(0);      
    }
    
    ///@notice register developer to developers, require msg.sender from the MC contract admin address lsit
    ///@param   _companyName    company name
    ///@param   _location    company location
    ///@param   _note   description of company and project
    function addNewDeveloper(
        string calldata _companyName, 
        string calldata _location,
        string calldata _note
    ) external override onlyAdmins {
        require(bytes(_companyName).length > 0,     "please do not leave name empty"    );
        require(bytes(_location).length > 0,     "please do not leave location empty"    );
        require(bytes(_note).length > 0,     "please do not leave note empty"    );

        // increment next developer ID
        nextDeveloperID++;

        // update info in _developer
        Developer storage _developer = getDeveloperByID[nextDeveloperID];
        _developer.companyName      = _companyName;
        _developer.location      = _location;
        _developer.note   = _note;
        _developer.developerID      = nextDeveloperID;
        _developer.myUniqueLoanEntityID.push(0);
        // store to active developer array
        activeDeveloperIDs.push(nextDeveloperID);
        // getDeveloperByID[nextDeveloperID] = _developer;                  //  index    0  1  2  active[1] = 1  active[2] = 2
        indexOfDeveloper[nextDeveloperID] = activeDeveloperIDs.length - 1;  // active = [0, 1, 2] indexOfDeveloper = [1, 2]        
        getDeveloperByID[nextDeveloperID].myActiveLandIDs.push(0);          // make sure myActiveLandIDs starts from 0
        isDeveloperIDValid[nextDeveloperID] = true; // set developer to valid

        // emit developer registration info
        emit NewDeveloperAdded(
            nextDeveloperID, 
            _companyName,
            _location,
            _note);
    }

     
    ///@notice update developer's info, require msg.sender from the MC contract admin address lsit
    ///@param   _developerID        developer identification numver should be in range (0, nextDeveloperID]
    ///@param   _companyName        company name
    ///@param   _location           company location
    ///@param   _note           company description
    function updateDeveloper(
        uint _developerID, 
        string calldata _companyName, 
        string calldata _location,
        string calldata _note
    ) external override onlyAdmins {
        require(isDeveloperIDValid[_developerID],   "Developer to be updated should be valid.");
        require(bytes(_companyName).length > 0,     "Please do not leave name empty."    );
        require(bytes(_location).length > 0,     "Please do not leave location empty."    );
        require(bytes(_note).length > 0,    "Please do not leave note empty." );
        // if user do not want to use current address
        Developer storage _developer = getDeveloperByID[_developerID];

        // update info in _developer
        _developer.companyName      = _companyName;
        _developer.location      = _location;
        _developer.note     = _note;

        // emit developer updated info
        emit DeveloperUpdated(
            _developerID, 
            _companyName,
            _location,
            _note);
    }


    ///@notice clear developer's info, require msg.sender from the MC contract admin address lsit
    ///@param   _developerID    developer identification numver should be in range (0, nextDeveloperID]
    function deleteDeveloper(uint _developerID) external override onlyAdmins {
        require(isDeveloperIDValid[_developerID], "Developer should be valid.");
        require(getDeveloperByID[_developerID].myActiveLandIDs.length == 1, "The develop has lands, cannot be deleted.");

        // set developer to invalid
        isDeveloperIDValid[_developerID] = false;

        // modify activeDeveloperIDs -> [1, 2, 3, 4] delete 2 -> [1, 4, 3]
        uint _indexOfLastDeveloper = activeDeveloperIDs.length - 1;
        uint _lastDeveloperID = activeDeveloperIDs[_indexOfLastDeveloper];
        uint _indexOfRemovedDeveloper = indexOfDeveloper[_developerID];
        // put last developerID to the position where we want to remove 
        activeDeveloperIDs[_indexOfRemovedDeveloper] = _lastDeveloperID;
        // modify indexOfDeveloper of last one and target
        indexOfDeveloper[_lastDeveloperID] = _indexOfRemovedDeveloper;
        indexOfDeveloper[_developerID] = 0; // set it to first element of activeDeveloperIDs
        activeDeveloperIDs.pop();   // pop the last element

        delete getDeveloperByID[_developerID];

        // emit developer deleted event
        emit DeveloperDeleted(_developerID);
    }


    ///@notice add new land's info, require msg.sender from the MC contract admin address lsit
    ///@param   _propertyIdentificationNumber   PIN number, official number for a land
    ///@param   _legalDescriptionOfProperty     legal description about the land
    ///@param   _typeOfOwnership    description of types of ownership
    ///@param   _registeredItems    items under the land
    ///@param   _developerID    developer identification numver should be in range (0, nextDeveloperID]
    function addNewLand(
        uint _propertyIdentificationNumber, 
        string calldata _legalDescriptionOfProperty, 
        string calldata _typeOfOwnership,
        string calldata _registeredItems,
        uint _developerID    
    ) external override onlyAdmins {
        require(_propertyIdentificationNumber != 0,                     "please do not leave PIN empty");
        require(bytes(_legalDescriptionOfProperty).length > 0,          "please do not leave legal description empty"    );
        require(bytes(_typeOfOwnership).length > 0,     "please do not leave type empty");
        require(bytes(_registeredItems).length > 0,     "please do not leave registered items empty");
        require(isDeveloperIDValid[_developerID], "Developer should be valid.");

        // increment developer number
        nextLandID++;

        // update info in _land
        Land storage _land = getLandByID[nextLandID];
        _land.propertyIdentificationNumber = _propertyIdentificationNumber;
        _land.legalDescriptionOfProperty = _legalDescriptionOfProperty;
        _land.typeOfOwnership = _typeOfOwnership;
        _land.registeredItems = _registeredItems;
        _land.isReady = false;
        _land.landID = nextLandID;
        _land.developerID = _developerID;
        // store to active land array
        activeLandIDs.push(nextLandID);
        indexOfLand[nextLandID] = activeLandIDs.length - 1;     // active = [0, 1, 2] indexOfDeveloper = [1, 2]
        isLandIDValid[nextLandID] = true;

        // update corresponding developer's info
        Developer storage _developer = getDeveloperByID[_developerID];
        _developer.myActiveLandIDs.push(nextLandID);
        _developer.myIndexOfLands[nextLandID] = _developer.myActiveLandIDs.length - 1;
        _developer.myUniqueLoanEntityID.push(0);
        // emit land registration event
        emit NewLandAdded(
            nextLandID, 
            _propertyIdentificationNumber, 
            _legalDescriptionOfProperty, 
            _typeOfOwnership, 
            _registeredItems, 
            _developerID);
    }


    ///@notice add new land's info, require msg.sender from the MC contract admin address lsit
    ///@param   _landID                         Land ID
    ///@param   _propertyIdentificationNumber   PIN number, official number for a land
    ///@param   _legalDescriptionOfProperty     legal description about the land
    ///@param   _typeOfOwnership    description of types of ownership
    ///@param   _registeredItems    items under the land
    //@param   _developerID    developer identification numver should be in range (0, developerNum]
    function updateLandBasicInfo(
        uint _landID,
        uint _propertyIdentificationNumber, 
        string calldata _legalDescriptionOfProperty, 
        string calldata _typeOfOwnership, 
        string calldata _registeredItems/*, 
        uint _developerID*/
    ) external override onlyAdmins {
        require(isLandIDValid[_landID],           "land should valid");
        require(_propertyIdentificationNumber > 0,              "please do not leave PIN empty" );
        require(bytes(_legalDescriptionOfProperty).length > 0,  "please do not leave legal description empty");
        require(bytes(_typeOfOwnership).length > 0,     "please do not leave type empty");
        require(bytes(_registeredItems).length > 0,     "please do not leave registered items empty");

        // update info in _land
        Land storage _land = getLandByID[_landID];
        _land.propertyIdentificationNumber = _propertyIdentificationNumber;
        _land.legalDescriptionOfProperty = _legalDescriptionOfProperty;
        _land.typeOfOwnership = _typeOfOwnership;
        _land.registeredItems = _registeredItems;

        // emit land basic info updated event
        emit LandBasicInfoUpdated(
            _landID, 
            _propertyIdentificationNumber, 
            _legalDescriptionOfProperty, 
            _typeOfOwnership, 
            _registeredItems/*, 
            _developerID*/);
    }


    ///@notice add new land's info, require msg.sender from the MC contract admin address lsit
    ///@param   _landID                         PIN number, official number for a land
    ///@param   _appraisalAmount                legal description about the land
    ///@param   _appraisalDiscountPercent     description of types of ownership
    //@param   _amountBorrowedByDeveloper      items under the land
    function addOrUpdateLandAppraisal(
        uint _landID, 
        uint _appraisalAmount, 
        uint _appraisalDiscountPercent
    ) external override onlyAdmins {
        require(isLandIDValid[_landID], "land should valid");
        require(_appraisalAmount > 0,   "please do not leave appraisal amount empty");
        require(_appraisalDiscountPercent > 0 && _appraisalDiscountPercent < 100 ,        
                                        "please do not leave discount empty");

        // update in lands
        Land storage _land = getLandByID[_landID];
        Developer storage _developer = getDeveloperByID[_land.developerID];

        uint num = 100;
        require(
            _appraisalDiscountPercent.mul(_appraisalAmount).div(num) >= _land.amountBorrowedByDeveloper,
            "The updated value and discount violate the used amount."
        );
        if(_land.isReady) {
            _developer.totalBorrowableValue = _developer.totalBorrowableValue.sub(_land.appraisalDiscountPercent.mul(_land.appraisalAmount).div(num));
        }
        _land.appraisalAmount = _appraisalAmount;
        _land.appraisalDiscountPercent = _appraisalDiscountPercent;
        
        // change apprasial record will cause valid -> false
        delete _land.votedAddresses;   // clear voted addresses
        _land.votedAddresses.push(msg.sender);
        _land.isReady = false;
        //_land.isCollateral = true;

        // emit land appraisal added or updated
        emit LandAppraisalAddedorUpdated(
            _landID, 
            _appraisalAmount, 
            _appraisalDiscountPercent/*, 
            _amountBorrowedByDeveloper*/);
    }


    ///@notice add new land's info, require msg.sender from the MC contract admin address lsit
    ///@param   _landID         land ID
    ///@param   _amountAdded    amount been brrowed out
    function updateAmountBorrowedByDeveloper(
        uint _landID, 
        uint _amountAdded
    ) external override onlyLOSC {
        require(isLandIDValid[_landID],                 "land should valid");
        require(_amountAdded > 0,                       "please do not leave borrowed amount empty");
        Land storage _land = getLandByID[_landID];
        require(_land.isReady,                          "The land should be ready");
        uint num = 100;
        uint currDebt = _amountAdded.add(_land.amountBorrowedByDeveloper);
        require(
            _land.appraisalDiscountPercent.mul(_land.appraisalAmount).div(num) >= currDebt,
            "Developer cannot overuse the approved amount"
        );

        // update in lands
        // TODO: only allow LOSC to update this function
        _land.amountBorrowedByDeveloper = currDebt;
        
        Developer storage _developer = getDeveloperByID[_land.developerID];
        _developer.totalAmountBorrowed += _amountAdded;

        // emit land appraisal borrowed by developer
        emit AmountBorrowedByDeveloperUpdated(_landID, _amountAdded);
    }


    ///@notice add new land's info, require msg.sender from the MC contract admin address lsit
    ///@param   _landID   LandID
    function approveLandAppraisal(
        uint _landID
    ) external override onlyAdmins {
        require(isLandIDValid[_landID],                 "land should valid");

        // update in lands
        Land storage _land = getLandByID[_landID];
        require(!_land.isReady, "only no-ready land needs approval");
        Developer storage _developer = getDeveloperByID[_land.developerID];

        // check msg.sender in votedAddresses array or not, if not, then put address in array
        if (exist(_land.votedAddresses, msg.sender) == false){
            _land.votedAddresses.push(msg.sender);
        }
        // if voted address meet the mini required num, then set to valid
        if (IManagementCompany(MCBoard).isVotesSufficient(_land.votedAddresses)){
            uint num = 100;
            _developer.totalBorrowableValue = _developer.totalBorrowableValue.add(_land.appraisalDiscountPercent.mul(_land.appraisalAmount).div(num));
            _land.isReady = true;
            delete _land.votedAddresses;
        }

        // emit land appraisal approved
        emit LandAppraisalApproved(_landID, _land.appraisalAmount);
    } 


    ///@notice delete land's info, require msg.sender from the MC contract admin address lsit
    ///@param   _landID   LandID
    function deleteLand(
        uint _landID
    ) external override onlyAdmins {
        require(isLandIDValid[_landID],  "land should be valid");
        Land storage _land = getLandByID[_landID]; 
        require(_land.amountBorrowedByDeveloper == 0);
        // set land to invalid
        isLandIDValid[_landID] = false;

        // modify activeLandIDs -> [1, 2, 3, 4] delete 2 -> [1, 4, 3]
        uint _indexOfLastLand = activeLandIDs.length - 1;
        uint _lastLandID = activeLandIDs[_indexOfLastLand];
        uint _indexOfRemovedLand = indexOfLand[_landID];
        // put last landID to the position where we want to remvoe 
        activeLandIDs[_indexOfRemovedLand] = _lastLandID;
        // modify indexOfLand of last one and target
        indexOfLand[_lastLandID] = _indexOfRemovedLand;
        indexOfLand[_landID] = 0;   // set it to first element of activeLandIDs
        activeLandIDs.pop();    // pop the last element

        //update developer
        Developer storage _developer = getDeveloperByID[getLandByID[_landID].developerID];
        // modify myActiveLandIDs -> [1, 2, 3, 4] delete 2 -> [1, 4, 3]
        uint _indexOfDeveloperLastActiveLand = _developer.myActiveLandIDs.length - 1;
        uint _lastDeveloperLandID = _developer.myActiveLandIDs[_indexOfDeveloperLastActiveLand];
        uint _indexOfDeveloperRemovedLandID = _developer.myIndexOfLands[_landID];
        // put last landID to the position where we want to remove 
        _developer.myActiveLandIDs[_indexOfDeveloperRemovedLandID] = _lastDeveloperLandID;
        // modify myIndexOfLands of last one and target
        _developer.myIndexOfLands[_lastDeveloperLandID] = _indexOfDeveloperRemovedLandID;
        _developer.myIndexOfLands[_landID] = 0;

        _developer.myActiveLandIDs.pop();
      
        uint num = 100;
        _developer.totalBorrowableValue = 
            _developer.totalBorrowableValue.sub( 
            _land.appraisalDiscountPercent.mul(_land.appraisalAmount).div(num));
         

        // update getLandByID
        delete getLandByID[_landID];

        // emit land deleted
        emit LandDeleted(_landID);
    }


    ///@notice helper function to check whether the msg.sender already in the land votedAddress array 
    ///@param   votedAddresses    all voted address array
    ///@param   user              msg.sender address
    function exist (address[] memory votedAddresses, address user) internal pure returns (bool){
      for (uint i = 0; i < votedAddresses.length; i++){
          if (user == votedAddresses[i]){
              return true;
          }
      }
      return false;
    }

    ///@notice necessary ActiveDeveloperIDs getter function for iterable struct mapping
    function getActiveDeveloperIDs() external view returns(uint[] memory result) {
        return activeDeveloperIDs;
    }

    ///@notice necessary ActiveLandIDs getter function for iterable struct mapping
    function getActiveLandIDs() external view returns(uint[] memory result) {
        return activeLandIDs;
    }

    ///@notice necessary vote Address getter function for land Struct
    function getVoteAddressByLandID(uint landID) external view returns(address[] memory result) {
        require(isLandIDValid[landID] == true, "Land Registration: Invalid Land ID.");
        Land storage land = getLandByID[landID];
        return land.votedAddresses;
    }

    function getLandAppraisalAmount(uint landID)  external override view returns (uint) {
        require(isLandIDValid[landID] == true, "Land Registration: Invalid Land ID.");
        Land storage land = getLandByID[landID];
        return land.appraisalAmount;
    }

    function addUniqueLoanEntityId(uint developerId, uint loanPoolID, uint loanEntityID) override external {
        require(ILoanOriginator(IManagementCompany(MCBoard).LOSCAddress()).getLoanPoolByID(loanPoolID) != address(0),
                "LandRegistration: online loanpool can call updateLandforNewLoanEntity");
        uint uniqueLoanEntityId = getUniqueLoanEntityId(loanPoolID, loanEntityID);
        Developer storage _developer = getDeveloperByID[developerId];
        _developer.myUniqueLoanEntityID.push(uniqueLoanEntityId);
        _developer.myUniqueLoanEntityIDIndex[uniqueLoanEntityId] = _developer.myUniqueLoanEntityID.length - 1;
    }

    function removeUniqueLoanEntityId(uint developerId, uint loanPoolId, uint loanEntityId) override external {
        require(ILoanOriginator(IManagementCompany(MCBoard).LOSCAddress()).getLoanPoolByID(loanPoolId) != address(0),
        "LandRegistration: online loanpool can call updateLandforNewLoanEntity");
        uint uniqueLoanEntityId = getUniqueLoanEntityId(loanPoolId, loanEntityId);
        Developer storage _developer = getDeveloperByID[developerId];
        uint length = _developer.myUniqueLoanEntityID.length;
        uint index = _developer.myUniqueLoanEntityIDIndex[uniqueLoanEntityId];
        _developer.myUniqueLoanEntityID[index] = _developer.myUniqueLoanEntityID[length - 1];
        _developer.myUniqueLoanEntityID.pop();
    }

    function getUniqueLoanEntityId(uint loanPoolId, uint loanEntityId) pure internal returns (uint uniqueLoanEntityId) {
        uniqueLoanEntityId = (loanPoolId << 128) | (loanEntityId);
    }

    function getLoanPoolIDAndEntityIds(uint uniqueLoanEntityId) pure internal returns (uint loanPoolId, uint loanEntityId) {
        loanPoolId = uniqueLoanEntityId >> 128;
        loanEntityId = uniqueLoanEntityId & ((1 << 128) - 1) ;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface ILandRegistration {

    // Land Developer Info
    struct Developer {
        string  companyName;
        string location;
        string note;
        uint    developerID;
        uint    totalBorrowableValue;
        uint    totalAmountBorrowed;
        uint[]  myActiveLandIDs;    // active land ID array
        mapping(uint => uint) myIndexOfLands;   // using landID -> index in the above land ID array
        // 128 bits LoanPool ID followed by 128 bits LoanEntity ID, 
        // called unique loan pool id 
        // (assume we have less than 2^128 loan pools and less than 2^128 loan entities per loan pool)
        uint[]  myUniqueLoanEntityID;    
        // unique loanpool ID -> index in the myUniqueLoanEntityID array
        mapping(uint => uint) myUniqueLoanEntityIDIndex;  
    }

    // Land Info
    struct Land {
        // basic info
        uint    propertyIdentificationNumber;
        string  legalDescriptionOfProperty;
        string  typeOfOwnership;
        string  registeredItems;
        bool    isReady;
        // vote related
        address[] votedAddresses;
        uint    landID;
        uint    developerID;
        // appraisal related
        uint    appraisalAmount;
        uint    appraisalDiscountPercent;
        uint    amountBorrowedByDeveloper; 
    }

    // CMP for info publication purposes
    // struct CommitmentMortgagePackage {
    //     uint    landID;
    //     uint    developerID;
    //     string  companyName;
    //     uint    propertyIdentificationNumber;
    //     string  legalDescriptionOfProperty; 
    //     uint    startDate;
    //     uint    closeDate;
    //     string  Notes;
    // }


    /// Developer Related Events
    event NewDeveloperAdded       (
        uint indexed developerID, 
        string  companyName,
        string  location,
        string  note);
    event DeveloperUpdated        (
        uint indexed developerID, 
        string  companyName,
        string  location,
        string  note);
    /// Land Related Events
    event NewLandAdded            (
        uint indexed landID, 
        uint propertyIdentificationNumber, 
        string legalDescriptionOfProperty, 
        string typeOfOwnership, 
        string registeredItems, 
        uint developerID);
    event LandBasicInfoUpdated    (
        uint indexed landID, 
        uint propertyIdentificationNumber, 
        string legalDescriptionOfProperty, 
        string typeOfOwnership, 
        string registeredItems);
    event LandAppraisalAddedorUpdated           (
        uint indexed landID, 
        uint appraisalAmount, 
        uint appraisalDiscountInPercent);
    event AmountBorrowedByDeveloperUpdated   (
        uint indexed landID, 
        uint amountBorrowedByDeveloper);
    event LandAppraisalApproved   (
        uint indexed landID, 
        uint newAppraisal);
    /// Developer & Land Delete
    event DeveloperDeleted  (uint indexed developerID); 
    event LandDeleted       (uint indexed landID);
    /// CMP Event
    // event CMPAnnounced      (
    //     uint indexed landID, 
    //     uint indexed developerID, 
    //     string companyName, 
    //     uint indexed propertyIdentificationNumber, 
    //     string legalDescriptionOfProperty, 
    //     uint startDate, 
    //     uint closeDate, 
    //     string Notes);

    /// Developer add & update & delete
    /// for developers: no approval needed from MC
    function addNewDeveloper(
        string calldata _companyName, 
        string calldata _location,
        string calldata _note) external;
    function updateDeveloper(
        uint _developerID, 
        string calldata _companyName, 
        string calldata _location,
        string calldata _note) external;

    /// Land add & update & appraisal update
    /// for lands: update basic info and uupdateAppraisalBorrowedByDeveloper() no need to approve
    ///            but for appraisal info update needs approval
    function addNewLand(
        uint _propertyIdentificationNumber, 
        string calldata _legalDescriptionOfProperty, 
        string calldata _typeOfOwnership, 
        string calldata _registeredItems, 
        uint _developerID) external;
    function updateLandBasicInfo(
        uint _landID, 
        uint _propertyIdentificationNumber, 
        string calldata _legalDescriptionOfProperty, 
        string calldata _typeOfOwnership, 
        string calldata _registeredItems) external;
    function addOrUpdateLandAppraisal(
        uint _landID, 
        uint _appraisalAmount, 
        uint _appraisalDiscountInPercent) external;
    // when SPV request draw fund -> accumulate in land info
    function updateAmountBorrowedByDeveloper(uint _landID, uint _amountAdded) external;
    function approveLandAppraisal(uint _landID) external;
    
    /// delete developer / land
    function deleteDeveloper(uint _developerID) external;
    function deleteLand(uint _landID) external;

    /// CMP function, create notice to boardcast
    // function createCMPAnnouncement(
    //     uint landID, 
    //     uint developerID, 
    //     uint startDate, 
    //     uint endDate, 
    //     string calldata notes) external;

    /// some helper functions to allow other contracts to interact
    function isDeveloperIDValid(uint developerID) external view returns (bool);
    function isLandIDValid(uint landID) external view returns (bool);
    function getLandAppraisalAmount(uint landID) external view returns (uint);
    function removeUniqueLoanEntityId(uint developerId, uint myId, uint loanEntityId) external;
    function addUniqueLoanEntityId(uint developerId, uint myId, uint loanEntityId) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IManagementCompany {
    event newAdminProposed(address indexed proposer, address indexed newPendingAdmin);
    event newSPVWalletAddressProposed(address indexed proposer, address indexed newSPVWalletAddress);
    event newLOSCAddressProposed(address indexed proposer, address indexed newSPVWalletAddress);
    event newMinApprovalRequiredProposed(address indexed proposer, uint indexed newNumber);
    event newMemberRemovalProposed(address indexed proposer, address indexed newPendingRemoveMember);

    event newAdminApproval(address indexed proposer, address indexed newPendingAdmin);
    event newSPVWalletAddressApproval(address indexed proposer, address indexed newSPVWalletAddress);
    event newLOSCAddressApproval(address indexed proposer, address indexed newSPVWalletAddress);
    event newMinApprovalRequiredApproval(address indexed proposer, uint indexed newNumber);
    event newMemberRemovalApproval(address indexed proposer, address indexed newPendingRemoveMember);

    event newAdminAppended(address indexed newPendingAdmin);
    event newSPVWalletAddressApproved(address indexed newSPVWalletAddress);
    event newLOSCAddressApproved(address indexed newSPVWalletAddress);
    event newMinApprovalRequiredUpdated(uint indexed newNumber);
    event memberRemoved(address indexed newPendingRemoveMember);

    function minApprovalRequired() external view returns (uint);
    function SPVWalletAddress() external returns (address);
    function LOSCAddress() external returns (address);
    function isMCAdmin(address admin) external returns (bool);


    function pendingMinApprovalRequired() external view returns (uint);
    function pendingSPVWalletAddress() external view returns (address);
    function pendingLOSCAddress() external view returns (address);
    function pendingMCBoardMember() external view returns (address);
    function pendingRemoveMember() external view returns (address);

    function proposeNewAdmin(address newAdmin) external;
    function proposeNewSPVWalletAddress(address newAdmin) external;
    function proposeNewLOSCAddress(address newAdmin) external;
    function proposeNewApprovalRequiredNumber(uint number) external;
    function proposeRemoveAdmin(address adminToBeRemoved) external;

    function approveNewAdmin() external;
    function approveNewSPVWalletAddress() external;
    function approveNewLOSCAddress() external;
    function approveNewApprovalRequiredNumber() external;
    function approveAdminRemoval() external;

    function isVotesSufficient(address[] memory votingFlags) external returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface ILoanOriginator {

     struct CommitmentMortgagePackage {
        uint packageID;
        uint landID;
        address developerID;
        uint startDate;
        uint closeDate;
        uint borrowingLimit;
        uint totalPrinciple;
        uint totalInterestObligated;
        bool status; 
    }

   event LoanPoolCreated(uint indexed minRate, uint indexed maxRate, address indexed loanPool, uint totalLoanPool);
   event LoanPoolClosed(address indexed loanPool);
   event LoanPoolOpen(address indexed loanPool);
   event CMPCreated(address indexed developerAddress, uint indexed landID, uint indexed principle);
   event PrincipleDrawn(uint indexed packageID, uint indexed principle);
   event FundPaid(uint indexed packageID, uint indexed principleToRepay, uint indexed interestToRepay);

   function createLoanPool(uint rate1, uint rate2, address _currency) external;
   function closeLoanPool(uint loanPoolID)  external;
   function openLoanPool(uint loanPoolID)  external;
   // lender operations
   function deposit(uint amount, uint loanPoolID) external;
   function withdraw(uint amountOfPoolToken, uint loanPoolID) external;
   // spv operations
   function drawFund(uint amount, uint loanPoolID, uint landID, uint developerID) external;
   function payLoan(uint amount, uint loanPoolID, uint loanEntity) external;
   function landDebtVoid(uint payableDebtAmount, uint landID) external;
   function debtVoid(uint payableDebtAmount, uint loanPoolID, uint loanEntity) external;

   // some helper functions to allow other contract to interact with
   function getLoanPoolByID(uint poolID) external view returns (address);
   function isLoanPoolIDValid(uint poolID) external view returns (bool);
   
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

{
  "optimizer": {
    "enabled": true,
    "runs": 200
  },
  "evmVersion": "istanbul",
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