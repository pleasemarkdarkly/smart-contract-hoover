// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Delegate.sol";

contract ClonesTesting  {
    event PairCreated(address pair);
    
    function figureItOut() public returns(address pair) {
        bytes memory bytecode = type(VerifyEIP712).runtimeCode;
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, block.difficulty));
        
        assembly {
            pair := create2(0, bytecode, mload(bytecode), salt)
        }
        
        emit PairCreated(pair);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;


contract VerifyEIP712  {
    uint256 public b; 
    constructor() {
        b = 3;
    }
    
    bytes32 constant public IDENTITY_TYPEHASH = keccak256("Identity(uint256 userId,address wallet)");
    bytes32 constant public BIDDER_TYPEHASH = keccak256("Bidder(uint256 amount,Identity bidder");
    
    // function hashStruct() {
        
    // }
}

{
  "optimizer": {
    "enabled": true,
    "runs": 1000
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