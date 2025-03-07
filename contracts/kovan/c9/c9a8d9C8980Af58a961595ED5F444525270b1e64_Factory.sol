// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract Factory {
  event Deployed(address _addr);
  function deploy(uint salt, bytes calldata bytecode) public {
    bytes memory implInitCode = bytecode;
    address addr;
    assembly {
        let encoded_data := add(0x20, implInitCode) // load initialization code.
        let encoded_size := mload(implInitCode)     // load init code's length.
        addr := create2(0, encoded_data, encoded_size, salt)
    }
    emit Deployed(addr);
  }
}

{
  "remappings": [],
  "optimizer": {
    "enabled": false,
    "runs": 200
  },
  "evmVersion": "berlin",
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