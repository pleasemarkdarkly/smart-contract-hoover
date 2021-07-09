# 🏠 smart-contract-hoover

| Folder       | Description   |
| ------------ | ------------- |
| contracts    | folder structure of dumped solidity contract sources (ethereum) |
| contracts_`chainProvider`    | folder structure of dumped solidity contract sources (other chains)|
| utils        | utilities for dumping smart contracts from public sources |

**Note**: This repo is updated twice a day.

## Folders

### Contracts

Contains smart contract sources for various networks, grouped by the first two chars of the contract address.
Files are named in the format `<address>_<source_unit_name>`, e.g. `0f0c3fedb6226cd5a18826ce23bec92d18336a98_URToken.sol`

Some contracts are listed in `contracts.json`, but this file is not complete. Rely on the file structure for a full list. 
This repo used to auto submit contracts to [4byte.directory](https://www.4byte.directory/). Feel free to contribute sources.


### Utils

Scripts for dumping smart contracts from public sources (etherscan.io, etherchain.com)

**requires:** `pip install -r requirements.txt`


#### Update

To use [List of Verified Contract addresses with an OpenSource license](https://etherscan.io/exportData?type=open-source-contract-codes), you can download the csv file, add it to the util folder, and run `parse_download_contracts_etherscan_io.py` (with your etherscan API). This will add the new contracts to the appropriate folder

## Contribute

Feel free to contribute smart contract sources, scripts for dumping sources or your analysis results with us.

### TODO

* dockerize 
* deduplication script (link instead of duplicate)
* statistics
* code-hash (without comments; maybe compile and hash bytecode to dedup sources)

## Citation
If you are using this dataset in your research and paper, here's how you can cite this dataset: 

- APA6
```
Ortner, M., Eskandari, S. (n.d.). Smart Contract Sanctuary. Retrieved from https://github.com/tintinweb/smart-contract-sanctuary.
```

- LateX (Bib)
```
 @article{smart_contract_sanctuary, 
          title={Smart Contract Sanctuary}, 
          url={https://github.com/tintinweb/smart-contract-sanctuary}, 
          author={Ortner, Martin and Eskandari, Shayan}} 
 ```
