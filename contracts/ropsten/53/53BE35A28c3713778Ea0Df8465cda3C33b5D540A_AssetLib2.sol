// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAssetFactory {
    function notDefaultDexRouterToken(address) external view returns (address);

    function notDefaultDexFactoryToken(address) external view returns (address);

    function defaultDexRouter() external view returns (address);

    function defaultDexFactory() external view returns (address);

    function weth() external view returns (address);

    function isAddressDexRouter(address) external view returns (bool);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOracle {
    function getData(address[] calldata tokens)
        external
        view
        returns (bool[] memory isValidValue, uint256[] memory tokensPrices);

    function uploadData(address[] calldata tokens, uint256[] calldata values) external;

    function getTimestampsOfLastUploads(address[] calldata tokens)
        external
        view
        returns (uint256[] memory timestamps);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../pancake-swap/interfaces/IPancakeRouter02.sol";
import "../pancake-swap/interfaces/IPancakeRouter02BNB.sol";
import "../pancake-swap/interfaces/IPancakeFactory.sol";
import "../pancake-swap/interfaces/IWETH.sol";

import "../interfaces/IOracle.sol";
import "../interfaces/IAssetFactory.sol";

library AssetLib {
    function calculateUserWeight(
        address user,
        address[] memory tokens,
        uint256[] memory tokenPricesInIme,
        mapping(address => mapping(address => uint256)) storage userEnters
    ) external view returns (uint256) {
        uint256 totalUserWeight;
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 decimals_;
            if (tokens[i] == address(0)) {
                decimals_ = 18;
            } else {
                decimals_ = IERC20Metadata(tokens[i]).decimals();
            }
            totalUserWeight +=
                (userEnters[user][tokens[i]] * tokenPricesInIme[i]) /
                (10**decimals_);
        }
        return totalUserWeight;
    }

    function checkIfTokensHavePair(address[] memory tokens, address assetFactory) public view {
        address defaultDexFactory = IAssetFactory(assetFactory).defaultDexFactory();
        address defaultDexRouter = IAssetFactory(assetFactory).defaultDexRouter();

        for (uint256 i = 0; i < tokens.length; ++i) {
            address dexFactory = IAssetFactory(assetFactory).notDefaultDexFactoryToken(tokens[i]);
            address dexRouter;
            address weth;
            if (dexFactory != address(0)) {
                dexRouter = IAssetFactory(assetFactory).notDefaultDexRouterToken(tokens[i]);
            } else {
                dexFactory = defaultDexFactory;
                dexRouter = defaultDexRouter;
            }
            weth = getWethFromDex(dexRouter);

            if (tokens[i] == weth) {
                continue;
            }
            bool isValid = checkIfAddressIsToken(tokens[i]);
            require(isValid == true, "Address is not token");

            address pair = IPancakeFactory(dexFactory).getPair(tokens[i], weth);
            require(pair != address(0), "Not have eth pair");
        }
    }

    function checkIfAddressIsToken(address token) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(token)
        }
        if (size == 0) {
            return false;
        }
        try IERC20Metadata(token).decimals() returns (uint8) {
            return true;
        } catch (bytes memory) {
            return false;
        }
    }

    function initTokenToBuyInfo(
        address[] memory tokensToBuy,
        uint256 totalWeight,
        mapping(address => uint256) storage tokensDistribution,
        IOracle oracle
    ) external view returns (uint256[][5] memory, uint256[] memory) {
        /*
        tokenToBuyInfo
        0 - tokens to buy amounts
        1 - actual number to buy (tokens to buy amounts - tokensInAssetNow)
        2 - actual weight to buy
        3 - tokens decimals
        4 - is in asset already
         */
        uint256[][5] memory tokenToBuyInfo;
        for (uint256 i = 0; i < tokenToBuyInfo.length; ++i) {
            tokenToBuyInfo[i] = new uint256[](tokensToBuy.length);
        }

        (bool[] memory isValidValue, uint256[] memory tokensPrices) = oracle.getData(tokensToBuy);
        for (uint256 i = 0; i < tokensToBuy.length; ++i) {
            require(isValidValue[i] == true, "Oracle price error");

            tokenToBuyInfo[3][i] = IERC20Metadata(tokensToBuy[i]).decimals();

            uint256 tokenWeight = (tokensDistribution[tokensToBuy[i]] * totalWeight) / 1e4;
            tokenToBuyInfo[0][i] = (tokenWeight * (10**tokenToBuyInfo[3][i])) / tokensPrices[i];
        }

        return (tokenToBuyInfo, tokensPrices);
    }

    function initTokenToSellInfo(
        address[] memory tokensOld,
        IOracle oracle,
        mapping(address => uint256) storage totalTokenAmount
    ) external view returns (uint256[][3] memory, uint256) {
        uint256[][3] memory tokensOldInfo;
        for (uint256 i = 0; i < tokensOldInfo.length; ++i) {
            tokensOldInfo[i] = new uint256[](tokensOld.length);
        }

        (bool[] memory isValidValue, uint256[] memory tokensPrices) = oracle.getData(tokensOld);
        uint256 oldWeight;
        for (uint256 i = 0; i < tokensOld.length; ++i) {
            tokensOldInfo[0][i] = totalTokenAmount[tokensOld[i]];
            tokensOldInfo[2][i] = IERC20Metadata(tokensOld[i]).decimals();
            require(isValidValue[i] == true, "Oracle error");
            oldWeight += (tokensOldInfo[0][i] * tokensPrices[i]) / (10**tokensOldInfo[2][i]);
        }
        require(oldWeight != 0, "No value in asset");

        return (tokensOldInfo, oldWeight);
    }

    function checkAndWriteDistribution(
        address[] memory newTokensInAsset,
        uint256[] memory distribution,
        address[] memory oldTokens,
        mapping(address => uint256) storage tokensDistribution
    ) external {
        require(newTokensInAsset.length == distribution.length, "Input error");
        require(newTokensInAsset.length > 0, "Len error");
        uint256 totalPerc;
        for (uint256 i = 0; i < newTokensInAsset.length; ++i) {
            require(newTokensInAsset[i] != address(0), "Wrong token");
            require(distribution[i] > 0, "Zero distribution");
            for (uint256 j = i + 1; j < newTokensInAsset.length; ++j) {
                require(newTokensInAsset[i] != newTokensInAsset[j], "Input error");
            }
            tokensDistribution[newTokensInAsset[i]] = distribution[i];
            totalPerc += distribution[i];
        }
        require(totalPerc == 1e4, "Perc error");

        for (uint256 i = 0; i < oldTokens.length; ++i) {
            bool isFound = false;
            for (uint256 j = 0; j < newTokensInAsset.length && isFound == false; ++j) {
                if (newTokensInAsset[j] == oldTokens[i]) {
                    isFound = true;
                }
            }

            if (isFound == false) {
                tokensDistribution[oldTokens[i]] = 0;
            }
        }
    }

    function withdrawFromYForOwner(
        address[] memory tokensInAsset,
        uint256[] memory tokenAmounts,
        address sender,
        mapping(address => uint256) storage yVaultAmount,
        mapping(address => uint256) storage yVaultAmountInStaking
    ) external {
        require(tokenAmounts.length == tokensInAsset.length, "Invalid input");
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 yAmount = yVaultAmount[tokensInAsset[i]];
            require(yAmount >= tokenAmounts[i], "Not enough y balance");
            yAmount -= tokenAmounts[i];
            yVaultAmount[tokensInAsset[i]] = yAmount;
            yVaultAmountInStaking[tokensInAsset[i]] += tokenAmounts[i];

            safeTransfer(tokensInAsset[i], sender, tokenAmounts[i]);
        }
    }

    function checkAndWriteWhitelist(
        address[] memory tokenWhitelist,
        address assetFactory,
        mapping(address => uint256) storage _whitelistIndexes,
        mapping(address => bool) storage isTokenWhitelisted
    ) external {
        checkIfTokensHavePair(tokenWhitelist, assetFactory);
        for (uint256 i = 0; i < tokenWhitelist.length; ++i) {
            require(tokenWhitelist[i] != address(0), "No zero address");
            for (uint256 j = 0; j < i; ++j) {
                require(tokenWhitelist[i] != tokenWhitelist[j], "Whitelist error");
            }
            _whitelistIndexes[tokenWhitelist[i]] = i;
            isTokenWhitelisted[tokenWhitelist[i]] = true;
        }
    }

    function changeWhitelist(
        address token,
        bool value,
        address assetFactory,
        address[] storage tokenWhitelist,
        mapping(address => bool) storage isTokenWhitelisted,
        mapping(address => uint256) storage whitelistIndexes
    ) external {
        require(token != address(0), "Token error");

        bool oldValue = isTokenWhitelisted[token];
        if (value == false && oldValue == true) {
            uint256 index = whitelistIndexes[token];
            uint256 len = tokenWhitelist.length;
            if (index < len - 1) {
                address newToken = tokenWhitelist[len - 1];
                tokenWhitelist[index] = newToken;
                whitelistIndexes[newToken] = index;
            }
            tokenWhitelist.pop();
        } else if (value == true && oldValue == false) {
            address[] memory temp = new address[](1);
            temp[0] = token;
            checkIfTokensHavePair(temp, assetFactory);
            whitelistIndexes[token] = tokenWhitelist.length;
            tokenWhitelist.push(token);
        } else {
            revert("Wrong value");
        }

        isTokenWhitelisted[token] = value;
    }

    function fillInformationInSellAndBuyTokens(
        address[] memory tokensInAssetNow,
        uint256[][3] memory tokensInAssetNowInfo,
        address[] memory tokensToBuy,
        uint256[][5] memory tokenToBuyInfo,
        uint256[] memory tokensPrices
    )
        external
        pure
        returns (
            uint256[][3] memory,
            uint256[][5] memory,
            uint256[2] memory
        )
    {
        for (uint256 i = 0; i < tokensInAssetNow.length; ++i) {
            bool isFound = false;
            for (uint256 j = 0; j < tokensToBuy.length && isFound == false; ++j) {
                if (tokensInAssetNow[i] == tokensToBuy[j]) {
                    isFound = true;
                    // mark that we found that token in asset already
                    tokenToBuyInfo[4][j] = 1;

                    if (tokenToBuyInfo[0][j] >= tokensInAssetNowInfo[0][i]) {
                        // if need to buy more than asset already have

                        // amount to sell = 0 (already 0)
                        //tokensInAssetNowInfo[1][i] = 0;

                        // actual amount to buy = (total amount to buy) - (amount in asset already)
                        tokenToBuyInfo[1][j] = tokenToBuyInfo[0][j] - tokensInAssetNowInfo[0][i];
                    } else {
                        // if need to buy less than asset already have

                        // amount to sell = (amount in asset already) - (total amount to buy)
                        tokensInAssetNowInfo[1][i] =
                            tokensInAssetNowInfo[0][i] -
                            tokenToBuyInfo[0][j];

                        // actual amount to buy = 0 (already 0)
                        //tokenToBuyInfo[1][j] = 0;
                    }
                }
            }

            // if we don't find token in _tokensToBuy than we need to sell it all
            if (isFound == false) {
                tokensInAssetNowInfo[1][i] = tokensInAssetNowInfo[0][i];
            }
        }

        // tokenToBuyInfoGlobals info
        // 0 - total weight to buy
        // 1 - number of true tokens to buy
        uint256[2] memory tokenToBuyInfoGlobals;
        for (uint256 i = 0; i < tokensToBuy.length; ++i) {
            if (tokenToBuyInfo[4][i] == 0) {
                // if no found in asset yet

                // actual weight to buy = (amount to buy) * (token price) / decimals
                tokenToBuyInfo[2][i] =
                    (tokenToBuyInfo[0][i] * tokensPrices[i]) /
                    (10**tokenToBuyInfo[3][i]);
            } else if (tokenToBuyInfo[1][i] != 0) {
                // if found in asset and amount to buy != 0

                // actual weight to buy = (actual amount to buy) * (token price) / decimals
                tokenToBuyInfo[2][i] =
                    (tokenToBuyInfo[1][i] * tokensPrices[i]) /
                    (10**tokenToBuyInfo[3][i]);
            } else {
                // if found in asset and amount to buy = 0
                continue;
            }
            // increase total weight
            tokenToBuyInfoGlobals[0] += tokenToBuyInfo[2][i];
            // increase number of true tokens to buy
            ++tokenToBuyInfoGlobals[1];
        }

        return (tokensInAssetNowInfo, tokenToBuyInfo, tokenToBuyInfoGlobals);
    }

    function sellTokensInAssetNow(
        address[] memory tokensInAssetNow,
        uint256[][3] memory tokensInAssetNowInfo,
        address weth,
        address assetFactory,
        mapping(address => uint256) storage totalTokenAmount
    ) external returns (uint256 availableWeth) {
        for (uint256 i = 0; i < tokensInAssetNow.length; ++i) {
            {
                address temp = tokensInAssetNow[i];
                if (totalTokenAmount[temp] == 0) {
                    totalTokenAmount[temp] = tokensInAssetNowInfo[0][i];
                }
            }

            if (tokensInAssetNowInfo[1][i] == 0) continue;

            if (tokensInAssetNow[i] == address(0)) {
                IWETH(weth).deposit{value: tokensInAssetNowInfo[1][i]}();
                availableWeth += tokensInAssetNowInfo[1][i];
            } else if (tokensInAssetNow[i] == address(weth)) {
                availableWeth += tokensInAssetNowInfo[1][i];
            } else if (tokensInAssetNow[i] != address(weth)) {
                availableWeth += safeSwap(
                    [tokensInAssetNow[i], weth],
                    tokensInAssetNowInfo[1][i],
                    assetFactory,
                    0
                );
            }
            {
                address temp = tokensInAssetNow[i];
                totalTokenAmount[temp] -= tokensInAssetNowInfo[1][i];
            }
        }
    }

    function buyTokensInAssetRebase(
        address[] memory tokensToBuy,
        uint256[][5] memory tokenToBuyInfo,
        uint256[2] memory tokenToBuyInfoGlobals,
        address weth,
        address assetFactory,
        uint256 availableWeth,
        mapping(address => uint256) storage totalTokenAmount
    ) external returns (uint256[] memory outputAmounts) {
        outputAmounts = new uint256[](tokensToBuy.length);
        if (tokenToBuyInfoGlobals[0] == 0 || availableWeth == 0) {
            return outputAmounts;
        }
        uint256 restWeth = availableWeth;
        for (uint256 i = 0; i < tokensToBuy.length && tokenToBuyInfoGlobals[1] > 0; ++i) {
            uint256 wethToSpend;
            // if actual weight to buy = 0
            if (tokenToBuyInfo[2][i] == 0) {
                continue;
            }
            if (tokenToBuyInfoGlobals[1] > 1) {
                wethToSpend = (availableWeth * tokenToBuyInfo[2][i]) / tokenToBuyInfoGlobals[0];
            } else {
                wethToSpend = restWeth;
            }
            require(wethToSpend > 0 && wethToSpend <= restWeth, "Internal error");

            restWeth -= wethToSpend;
            --tokenToBuyInfoGlobals[1];

            outputAmounts[i] = safeSwap([weth, tokensToBuy[i]], wethToSpend, assetFactory, 1);

            {
                address temp = tokensToBuy[i];
                totalTokenAmount[temp] += outputAmounts[i];
            }
        }

        require(restWeth == 0, "Internal error");

        return outputAmounts;
    }

    function transferTokenAndSwapToWeth(
        address tokenToPay,
        uint256 amount,
        address sender,
        address weth,
        address assetFactory
    ) external returns (address, uint256) {
        tokenToPay = transferFromToGoodToken(tokenToPay, sender, amount, weth);
        uint256 totalWeth;
        if (tokenToPay == weth) {
            totalWeth = amount;
        } else {
            totalWeth = safeSwap([tokenToPay, weth], amount, assetFactory, 0);
        }

        return (tokenToPay, totalWeth);
    }

    function transferFromToGoodToken(
        address token,
        address user,
        uint256 amount,
        address weth
    ) public returns (address) {
        if (token == address(0)) {
            require(msg.value == amount, "Value error");
            token = weth;
            IWETH(weth).deposit{value: amount}();
        } else {
            require(msg.value == 0, "Value error");
            AssetLib.safeTransferFrom(token, user, amount);
        }
        return token;
    }

    function checkCurrency(
        address currency,
        address weth,
        mapping(address => bool) storage isTokenWhitelisted
    ) external view {
        address currencyToCheck;
        if (currency == address(0)) {
            currencyToCheck = weth;
        } else {
            currencyToCheck = currency;
        }
        require(isTokenWhitelisted[currencyToCheck], "Not allowed currency");
    }

    function buyTokensMint(
        uint256 totalWeth,
        address[] memory tokensInAsset,
        address[2] memory wethAndAssetFactory,
        mapping(address => uint256) storage tokensDistribution,
        mapping(address => uint256) storage totalTokenAmount
    ) external returns (uint256[] memory buyAmounts, uint256[] memory oldDistribution) {
        buyAmounts = new uint256[](tokensInAsset.length);
        oldDistribution = new uint256[](tokensInAsset.length);
        uint256 restWeth = totalWeth;
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 wethToThisToken;
            if (i < tokensInAsset.length - 1) {
                wethToThisToken = (totalWeth * tokensDistribution[tokensInAsset[i]]) / 1e4;
            } else {
                wethToThisToken = restWeth;
            }
            require(wethToThisToken > 0 && wethToThisToken <= restWeth, "Internal error");

            restWeth -= wethToThisToken;

            oldDistribution[i] = totalTokenAmount[tokensInAsset[i]];

            buyAmounts[i] = safeSwap(
                [wethAndAssetFactory[0], tokensInAsset[i]],
                wethToThisToken,
                wethAndAssetFactory[1],
                1
            );

            totalTokenAmount[tokensInAsset[i]] = oldDistribution[i] + buyAmounts[i];
        }
    }

    function getMintAmount(
        address[] memory tokensInAsset,
        uint256[] memory buyAmounts,
        uint256[] memory oldDistribution,
        uint256 totalSupply,
        uint256 decimals,
        IOracle oracle
    ) public view returns (uint256 mintAmount) {
        uint256 totalPriceInAsset;
        uint256 totalPriceUser;
        (bool[] memory isValidValue, uint256[] memory tokensPrices) = oracle.getData(tokensInAsset);
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            require(isValidValue[i] == true, "Oracle error");
            uint256 decimalsToken = IERC20Metadata(tokensInAsset[i]).decimals();
            totalPriceInAsset += (oldDistribution[i] * tokensPrices[i]) / (10**decimalsToken);
            totalPriceUser += (buyAmounts[i] * tokensPrices[i]) / (10**decimalsToken);
        }

        if (totalPriceInAsset == 0 || totalSupply == 0) {
            return 10**decimals;
        } else {
            return (totalSupply * totalPriceUser) / totalPriceInAsset;
        }
    }

    function safeSwap(
        address[2] memory path,
        uint256 amount,
        address assetFactory,
        uint256 forWhatTokenDex
    ) public returns (uint256) {
        if (path[0] == path[1]) {
            return amount;
        }

        address dexRouter = getTokenDexRouter(assetFactory, path[forWhatTokenDex]);
        checkAllowance(path[0], dexRouter, amount);

        address[] memory _path = new address[](2);
        _path[0] = path[0];
        _path[1] = path[1];
        uint256[] memory amounts = IPancakeRouter02(dexRouter).swapExactTokensForTokens(
            amount,
            0,
            _path,
            address(this),
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
        );

        return amounts[1];
    }

    function redeemAndTransfer(
        uint256[2] memory amountAndTotalSupply,
        address[4] memory userCurrencyToPayWethFactory,
        mapping(address => uint256) storage totalTokenAmount,
        address[] memory tokensInAsset,
        uint256[] memory feePercentages
    )
        public
        returns (
            uint256 feeTotal,
            uint256[] memory inputAmounts,
            uint256 outputAmountTotal
        )
    {
        inputAmounts = new uint256[](tokensInAsset.length);
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            inputAmounts[i] =
                (totalTokenAmount[tokensInAsset[i]] * amountAndTotalSupply[0]) /
                amountAndTotalSupply[1];

            uint256 outputAmount = swapToCurrency(
                tokensInAsset[i],
                userCurrencyToPayWethFactory[1],
                inputAmounts[i],
                [userCurrencyToPayWethFactory[2], userCurrencyToPayWethFactory[3]]
            );

            uint256 fee = (outputAmount * feePercentages[i]) / 1e4;
            outputAmountTotal += outputAmount - fee;
            feeTotal += fee;

            totalTokenAmount[tokensInAsset[i]] -= inputAmounts[i];
        }

        if (userCurrencyToPayWethFactory[1] == address(0)) {
            IWETH(userCurrencyToPayWethFactory[2]).withdraw(outputAmountTotal);
            safeTransfer(address(0), userCurrencyToPayWethFactory[0], outputAmountTotal);
        } else {
            safeTransfer(
                userCurrencyToPayWethFactory[1],
                userCurrencyToPayWethFactory[0],
                outputAmountTotal
            );
        }
    }

    function initTokenInfoFromWhitelist(
        address[] memory tokensWhitelist,
        mapping(address => uint256) storage tokenEntersIme
    ) external view returns (uint256[][3] memory tokensIncomeAmounts) {
        tokensIncomeAmounts[0] = new uint256[](tokensWhitelist.length);
        tokensIncomeAmounts[1] = new uint256[](tokensWhitelist.length);
        tokensIncomeAmounts[2] = new uint256[](tokensWhitelist.length);
        for (uint256 i = 0; i < tokensWhitelist.length; ++i) {
            tokensIncomeAmounts[0][i] = tokenEntersIme[tokensWhitelist[i]];
            tokensIncomeAmounts[2][i] = IERC20Metadata(tokensWhitelist[i]).decimals();
        }
    }

    function calculateXYAfterIme(
        address[] memory tokensInAsset,
        mapping(address => uint256) storage totalTokenAmount,
        mapping(address => uint256) storage xVaultAmount,
        mapping(address => uint256) storage yVaultAmount
    ) external {
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 amountTotal = totalTokenAmount[tokensInAsset[i]];
            uint256 amountToX = (amountTotal * 2000) / 1e4;

            xVaultAmount[tokensInAsset[i]] = amountToX;
            yVaultAmount[tokensInAsset[i]] = amountTotal - amountToX;
        }
    }

    function depositToY(
        address[] memory tokensInAsset,
        uint256[] memory tokenAmountsOfY,
        address[] memory tokensOfDividends,
        uint256[] memory amountOfDividends,
        address sender,
        address assetFactory,
        address weth,
        mapping(address => uint256) storage yVaultAmountInStaking,
        mapping(address => uint256) storage yVaultAmount
    ) external returns (uint256) {
        require(tokensInAsset.length == tokenAmountsOfY.length, "Input error 1");
        require(tokensOfDividends.length == amountOfDividends.length, "Input error 2");

        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 amountInStaking = yVaultAmountInStaking[tokensInAsset[i]];
            require(amountInStaking >= tokenAmountsOfY[i], "Trying to send more");
            amountInStaking -= tokenAmountsOfY[i];
            yVaultAmountInStaking[tokensInAsset[i]] = amountInStaking;
            yVaultAmount[tokensInAsset[i]] += tokenAmountsOfY[i];

            safeTransferFrom(tokensInAsset[i], sender, tokenAmountsOfY[i]);
        }

        uint256 totalWeth;
        for (uint256 i = 0; i < tokensOfDividends.length; ++i) {
            safeTransferFrom(tokensOfDividends[i], sender, amountOfDividends[i]);
            totalWeth += safeSwap(
                [tokensOfDividends[i], weth],
                amountOfDividends[i],
                assetFactory,
                0
            );
        }
        return totalWeth;
    }

    function proceedIme(
        address[] memory tokens,
        IOracle oracle,
        mapping(address => uint256) storage tokenEntersIme
    ) external view returns (uint256, uint256[] memory) {
        (bool[] memory isValidValue, uint256[] memory tokensPrices) = oracle.getData(tokens);

        uint256 totalWeight;
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(isValidValue[i] == true, "Not valid oracle values");
            uint256 decimals_ = IERC20Metadata(tokens[i]).decimals();
            totalWeight += (tokenEntersIme[tokens[i]] * tokensPrices[i]) / (10**decimals_);
        }

        return (totalWeight, tokensPrices);
    }

    function getFeePercentagesRedeem(
        address[] memory tokensInAsset,
        mapping(address => uint256) storage totalTokenAmount,
        mapping(address => uint256) storage xVaultAmount
    ) external view returns (uint256[] memory feePercentages) {
        feePercentages = new uint256[](tokensInAsset.length);

        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 totalAmount = totalTokenAmount[tokensInAsset[i]];
            uint256 xAmount = xVaultAmount[tokensInAsset[i]];

            if (xAmount >= (1500 * totalAmount) / 1e4) {
                feePercentages[i] = 200;
            } else if (
                xAmount < (1500 * totalAmount) / 1e4 && xAmount >= (500 * totalAmount) / 1e4
            ) {
                uint256 xAmountPertcentage = (xAmount * 1e4) / totalAmount;
                feePercentages[i] = 600 - (400 * (xAmountPertcentage - 500)) / 1000;
            } else {
                revert("xAmount percentage error");
            }
        }
    }

    function swapToCurrency(
        address inputCurrency,
        address outputCurrency,
        uint256 amount,
        address[2] memory wethAndAssetFactory
    ) internal returns (uint256) {
        require(inputCurrency != address(0), "Internal error");
        if (inputCurrency != outputCurrency) {
            uint256 outputAmount;
            if (outputCurrency == wethAndAssetFactory[0] || outputCurrency == address(0)) {
                outputAmount = safeSwap(
                    [inputCurrency, wethAndAssetFactory[0]],
                    amount,
                    wethAndAssetFactory[1],
                    0
                );
            } else {
                outputAmount = safeSwap(
                    [inputCurrency, wethAndAssetFactory[0]],
                    amount,
                    wethAndAssetFactory[1],
                    0
                );
                outputAmount = safeSwap(
                    [wethAndAssetFactory[0], outputCurrency],
                    outputAmount,
                    wethAndAssetFactory[1],
                    1
                );
            }
            return outputAmount;
        } else {
            return amount;
        }
    }

    function safeTransferFrom(
        address token,
        address from,
        uint256 amount
    ) internal {
        if (token == address(0)) {
            require(msg.value == amount, "Value error");
        } else {
            require(IERC20(token).transferFrom(from, address(this), amount), "TransferFrom failed");
        }
    }

    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) public {
        if (to == address(this)) {
            return;
        }
        if (token == address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = to.call{value: amount}(new bytes(0));
            require(success, "Transfer eth failed");
        } else {
            require(IERC20(token).transfer(to, amount), "Transfer token failed");
        }
    }

    function checkAllowance(
        address token,
        address to,
        uint256 amount
    ) public {
        uint256 allowance = IERC20(token).allowance(address(this), to);

        if (amount > allowance) {
            IERC20(token).approve(to, type(uint256).max);
        }
    }

    function getWethFromDex(address dexRouter) public view returns (address) {
        try IPancakeRouter02(dexRouter).WETH() returns (address weth) {
            return weth;
        } catch (bytes memory) {}

        try IPancakeRouter02BNB(dexRouter).WBNB() returns (address weth) {
            return weth;
        } catch (bytes memory) {
            return address(0);
        }
    }

    function getTokenDexRouter(address factory, address token) public view returns (address) {
        address customDexRouter = IAssetFactory(factory).notDefaultDexRouterToken(token);

        if (customDexRouter != address(0)) {
            return customDexRouter;
        } else {
            return IAssetFactory(factory).defaultDexRouter();
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../pancake-swap/interfaces/IPancakeRouter02.sol";
import "../pancake-swap/interfaces/IPancakeRouter02BNB.sol";
import "../pancake-swap/interfaces/IWETH.sol";

import "../interfaces/IOracle.sol";

import "./AssetLib.sol";

library AssetLib2 {
    function calculateBuyAmountOut(
        uint256 amount,
        address currencyIn,
        address[] memory tokensInAsset,
        address[3] memory wethAssetFactoryAndOracle,
        uint256[2] memory totalSupplyAndDecimals,
        mapping(address => uint256) storage tokensDistribution,
        mapping(address => uint256) storage totalTokenAmount
    ) external view returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        address[] memory path = new address[](2);
        if (currencyIn == address(0)) {
            currencyIn = wethAssetFactoryAndOracle[0];
        }
        if (currencyIn != wethAssetFactoryAndOracle[0]) {
            path[0] = currencyIn;
            path[1] = wethAssetFactoryAndOracle[0];
            address dexRouter = AssetLib.getTokenDexRouter(
                wethAssetFactoryAndOracle[1],
                currencyIn
            );
            try IPancakeRouter02(dexRouter).getAmountsOut(amount, path) returns (
                uint256[] memory amounts
            ) {
                amount = amounts[1];
            } catch (bytes memory) {
                amount = 0;
            }
        }
        if (amount == 0) {
            return 0;
        }
        amount -= (amount * 50) / 1e4;
        uint256 restAmount = amount;
        uint256[][2] memory buyAmountsAndDistribution;
        buyAmountsAndDistribution[0] = new uint256[](tokensInAsset.length);
        buyAmountsAndDistribution[1] = new uint256[](tokensInAsset.length);
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 wethToThisToken;
            buyAmountsAndDistribution[1][i] = totalTokenAmount[tokensInAsset[i]];
            if (i < tokensInAsset.length - 1) {
                wethToThisToken = (amount * tokensDistribution[tokensInAsset[i]]) / 1e4;
            } else {
                wethToThisToken = restAmount;
            }
            restAmount -= wethToThisToken;

            if (tokensInAsset[i] != wethAssetFactoryAndOracle[0]) {
                path[0] = wethAssetFactoryAndOracle[0];
                path[1] = tokensInAsset[i];
                address dexRouter = AssetLib.getTokenDexRouter(
                    wethAssetFactoryAndOracle[1],
                    tokensInAsset[i]
                );
                try IPancakeRouter02(dexRouter).getAmountsOut(wethToThisToken, path) returns (
                    uint256[] memory amounts
                ) {
                    buyAmountsAndDistribution[0][i] = amounts[1];
                } catch (bytes memory) {
                    buyAmountsAndDistribution[0][i] = 0;
                }
            } else {
                buyAmountsAndDistribution[0][i] = wethToThisToken;
            }
        }

        return
            AssetLib.getMintAmount(
                tokensInAsset,
                buyAmountsAndDistribution[0],
                buyAmountsAndDistribution[1],
                totalSupplyAndDecimals[0],
                totalSupplyAndDecimals[1],
                IOracle(wethAssetFactoryAndOracle[2])
            );
    }

    function calculateSellAmountOut(
        uint256[2] memory amountAndTotalSupply,
        address currencyToPay,
        address[] memory tokensInAsset,
        address[2] memory wethAndAssetFactory,
        mapping(address => uint256) storage totalTokenAmount,
        mapping(address => uint256) storage xVaultAmount
    ) external view returns (uint256) {
        if (amountAndTotalSupply[0] == 0 || amountAndTotalSupply[1] == 0) {
            return 0;
        }
        if (currencyToPay == address(0)) {
            currencyToPay = wethAndAssetFactory[0];
        }
        uint256[] memory feePercentages = AssetLib.getFeePercentagesRedeem(
            tokensInAsset,
            totalTokenAmount,
            xVaultAmount
        );

        address[] memory path = new address[](2);
        uint256 outputAmountTotal;
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 inputAmount = (totalTokenAmount[tokensInAsset[i]] * amountAndTotalSupply[0]) /
                amountAndTotalSupply[1];

            if (inputAmount == 0) {
                continue;
            }

            uint256 outputAmount;
            if (tokensInAsset[i] != currencyToPay) {
                if (
                    currencyToPay == wethAndAssetFactory[0] ||
                    tokensInAsset[i] == wethAndAssetFactory[0]
                ) {
                    address dexRouter;
                    if (tokensInAsset[i] != wethAndAssetFactory[0]) {
                        dexRouter = AssetLib.getTokenDexRouter(
                            wethAndAssetFactory[1],
                            tokensInAsset[i]
                        );
                    } else {
                        dexRouter = AssetLib.getTokenDexRouter(
                            wethAndAssetFactory[1],
                            currencyToPay
                        );
                    }
                    path[0] = tokensInAsset[i];
                    path[1] = currencyToPay;
                    try IPancakeRouter02(dexRouter).getAmountsOut(inputAmount, path) returns (
                        uint256[] memory amounts
                    ) {
                        outputAmount = amounts[1];
                    } catch (bytes memory) {
                        outputAmount = 0;
                    }
                } else {
                    address dexRouter = AssetLib.getTokenDexRouter(
                        wethAndAssetFactory[1],
                        tokensInAsset[i]
                    );
                    path[0] = tokensInAsset[i];
                    path[1] = wethAndAssetFactory[0];
                    try IPancakeRouter02(dexRouter).getAmountsOut(inputAmount, path) returns (
                        uint256[] memory amounts
                    ) {
                        outputAmount = amounts[1];
                    } catch (bytes memory) {
                        outputAmount = 0;
                        continue;
                    }

                    dexRouter = AssetLib.getTokenDexRouter(wethAndAssetFactory[1], currencyToPay);
                    path[0] = wethAndAssetFactory[0];
                    path[1] = currencyToPay;
                    try IPancakeRouter02(dexRouter).getAmountsOut(outputAmount, path) returns (
                        uint256[] memory amounts
                    ) {
                        outputAmount = amounts[1];
                    } catch (bytes memory) {
                        outputAmount = 0;
                    }
                }
            } else {
                outputAmount = inputAmount;
            }

            uint256 fee = (outputAmount * feePercentages[i]) / 1e4;
            outputAmountTotal += outputAmount - fee;
        }

        return outputAmountTotal;
    }

    function xyDistributionAfterMint(
        address[] memory tokensInAsset,
        uint256[] memory buyAmounts,
        uint256[] memory oldDistribution,
        mapping(address => uint256) storage xVaultAmount,
        mapping(address => uint256) storage yVaultAmount
    ) external {
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 totalAmount = buyAmounts[i] + oldDistribution[i];
            uint256 maxAmountInX = (totalAmount * 2000) / 1e4;

            uint256 amountInXOld = xVaultAmount[tokensInAsset[i]];
            uint256 restAmountToDistribute = buyAmounts[i];
            if (amountInXOld < maxAmountInX) {
                amountInXOld += restAmountToDistribute;
                if (amountInXOld > maxAmountInX) {
                    uint256 delta = amountInXOld - maxAmountInX;
                    amountInXOld = maxAmountInX;
                    restAmountToDistribute = delta;
                } else {
                    restAmountToDistribute = 0;
                }
            }

            if (restAmountToDistribute > 0) {
                yVaultAmount[tokensInAsset[i]] += restAmountToDistribute;
            }

            xVaultAmount[tokensInAsset[i]] = amountInXOld;
        }
    }

    function xyDistributionAfterRedeem(
        mapping(address => uint256) storage totalTokenAmount,
        bool isAllowedAutoXYRebalace,
        mapping(address => uint256) storage xVaultAmount,
        mapping(address => uint256) storage yVaultAmount,
        address[] memory tokensInAsset,
        uint256[] memory sellAmounts
    ) public {
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 totalAmount = totalTokenAmount[tokensInAsset[i]];
            uint256 xStopAmount = (totalAmount * 500) / 1e4;
            uint256 xAmountMax = (totalAmount * 2000) / 1e4;

            uint256 xAmount = xVaultAmount[tokensInAsset[i]];
            if (isAllowedAutoXYRebalace == true) {
                uint256 yAmount = yVaultAmount[tokensInAsset[i]];
                require(
                    xAmount + yAmount >= sellAmounts[i] &&
                        xAmount + yAmount - sellAmounts[i] >= xStopAmount,
                    "Not enough XY"
                );
                if (xAmount >= sellAmounts[i] && xAmount - sellAmounts[i] >= xStopAmount) {
                    xAmount -= sellAmounts[i];
                } else {
                    xAmount += yAmount;
                    xAmount -= sellAmounts[i];
                    if (xAmount > xAmountMax) {
                        uint256 delta = xAmount - xAmountMax;
                        yAmount = delta;
                        xAmount = xAmountMax;

                        yVaultAmount[tokensInAsset[i]] = yAmount;
                    }
                }
            } else {
                require(
                    xAmount >= sellAmounts[i] && xAmount - sellAmounts[i] >= xStopAmount,
                    "Not enough X"
                );
                xAmount -= sellAmounts[i];
            }
            xVaultAmount[tokensInAsset[i]] = xAmount;
        }
    }

    function xyDistributionAfterRebase(
        address[] memory tokensInAssetNow,
        uint256[] memory tokensInAssetNowSellAmounts,
        address[] memory tokensToBuy,
        uint256[] memory tokenToBuyAmounts,
        mapping(address => uint256) storage xVaultAmount,
        mapping(address => uint256) storage yVaultAmount,
        mapping(address => uint256) storage totalTokenAmount
    ) external {
        for (uint256 i = 0; i < tokensInAssetNow.length; ++i) {
            uint256 xAmount = xVaultAmount[tokensInAssetNow[i]];
            uint256 yAmount = yVaultAmount[tokensInAssetNow[i]];

            require(
                xAmount + yAmount >= tokensInAssetNowSellAmounts[i],
                "Not enought value in asset"
            );
            if (tokensInAssetNowSellAmounts[i] > yAmount) {
                xAmount -= tokensInAssetNowSellAmounts[i] - yAmount;
                yAmount = 0;
                xVaultAmount[tokensInAssetNow[i]] = xAmount;
                yVaultAmount[tokensInAssetNow[i]] = yAmount;
            } else {
                yAmount -= tokensInAssetNowSellAmounts[i];
                yVaultAmount[tokensInAssetNow[i]] = yAmount;
            }
        }

        for (uint256 i = 0; i < tokensToBuy.length; ++i) {
            uint256 xAmount = xVaultAmount[tokensToBuy[i]];
            uint256 yAmount = yVaultAmount[tokensToBuy[i]];
            uint256 xMaxAmount = (totalTokenAmount[tokensToBuy[i]] * 2000) / 1e4;

            xAmount += tokenToBuyAmounts[i];
            if (xAmount > xMaxAmount) {
                yAmount += xAmount - xMaxAmount;
                xAmount = xMaxAmount;
                xVaultAmount[tokensToBuy[i]] = xAmount;
                yVaultAmount[tokensToBuy[i]] = yAmount;
            } else {
                xVaultAmount[tokensToBuy[i]] = xAmount;
            }
        }
    }

    function xyRebalance(
        uint256 xPercentage,
        address[] memory tokensInAsset,
        mapping(address => uint256) storage xVaultAmount,
        mapping(address => uint256) storage yVaultAmount,
        mapping(address => uint256) storage totalTokenAmount
    ) external {
        for (uint256 i = 0; i < tokensInAsset.length; ++i) {
            uint256 totalAmount = totalTokenAmount[tokensInAsset[i]];
            uint256 xAmount = xVaultAmount[tokensInAsset[i]];
            uint256 yAmount = yVaultAmount[tokensInAsset[i]];
            uint256 xAmountDesired = (totalAmount * xPercentage) / 1e4;

            if (xAmount > xAmountDesired) {
                yAmount += xAmount - xAmountDesired;
                xAmount = xAmountDesired;
                xVaultAmount[tokensInAsset[i]] = xAmount;
                yVaultAmount[tokensInAsset[i]] = yAmount;
            } else if (xAmount < xAmountDesired) {
                uint256 delta = xAmountDesired - xAmount;
                require(yAmount >= delta, "Not enough value in Y");
                xAmount += delta;
                yAmount -= delta;
            } else {
                continue;
            }
            xVaultAmount[tokensInAsset[i]] = xAmount;
            yVaultAmount[tokensInAsset[i]] = yAmount;
        }
    }

    function swapTokensDex(
        address dexRouter,
        address[] memory path,
        uint256 amount
    ) external returns (uint256, bool) {
        try
            IPancakeRouter02(dexRouter).swapExactTokensForETH(
                amount,
                0,
                path,
                address(this),
                block.timestamp
            )
        returns (uint256[] memory amounts) {
            return (amounts[1], true);
        } catch (bytes memory) {}

        try
            IPancakeRouter02BNB(dexRouter).swapExactTokensForBNB(
                amount,
                0,
                path,
                address(this),
                block.timestamp
            )
        returns (uint256[] memory amounts) {
            return (amounts[1], true);
        } catch (bytes memory) {
            return (0, false);
        }
    }

    function addLiquidityETH(
        address dexRouter,
        address token,
        uint256 amount
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        AssetLib.checkAllowance(token, dexRouter, amount);
        try
            IPancakeRouter02(dexRouter).addLiquidityETH(
                token,
                amount,
                0,
                0,
                address(this),
                block.timestamp
            )
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
            return (amountToken, amountETH, liquidity);
        } catch (bytes memory) {}

        try
            IPancakeRouter02BNB(dexRouter).addLiquidityBNB(
                token,
                amount,
                0,
                0,
                address(this),
                block.timestamp
            )
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
            return (amountToken, amountETH, liquidity);
        } catch Error(string memory reason) {
            revert(reason);
        }
        /* catch (bytes memory) {
            revert("Wriong dex router");
        } */
    }

    function removeLiquidityBNB(
        address dexRouter,
        address token,
        address goodToken,
        uint256 amount
    )
        external
        returns (
            uint256,
            uint256,
            bool
        )
    {
        AssetLib.checkAllowance(token, dexRouter, amount);
        try
            IPancakeRouter02(dexRouter).removeLiquidityETH(
                goodToken,
                amount,
                0,
                0,
                address(this),
                block.timestamp
            )
        returns (uint256 amountToken, uint256 amountETH) {
            return (amountToken, amountETH, true);
        } catch Error(string memory reason) {
            if (compareStrings(reason, string("revert")) == 0) {
                return (0, 0, false);
            }
        }

        try
            IPancakeRouter02BNB(dexRouter).removeLiquidityBNB(
                goodToken,
                amount,
                0,
                0,
                address(this),
                block.timestamp
            )
        returns (uint256 amountToken, uint256 amountETH) {
            return (amountToken, amountETH, true);
        } catch (bytes memory) {
            return (0, 0, false);
        }
        /* catch (bytes memory) {
            revert("Wriong dex router");
        } */
    }

    function compareStrings(string memory _a, string memory _b) internal pure returns (int256) {
        bytes memory a = bytes(_a);
        bytes memory b = bytes(_b);
        uint256 minLength = a.length;
        if (b.length < minLength) minLength = b.length;
        //@todo unroll the loop into increments of 32 and do full 32 byte comparisons
        for (uint256 i = 0; i < minLength; i++)
            if (a[i] < b[i]) return -1;
            else if (a[i] > b[i]) return 1;
        if (a.length < b.length) return -1;
        else if (a.length > b.length) return 1;
        else return 0;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPancakeFactory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPancakeRouter01 {
    function factory() external view returns (address);

    function WETH() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPancakeRouter01BNB {
    function factory() external view returns (address);

    function WBNB() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityBNB(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountBNB,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityBNB(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountBNB);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityBNBWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountBNB);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactBNBForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactBNB(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForBNB(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapBNBForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IPancakeRouter01.sol";

interface IPancakeRouter02 is IPancakeRouter01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IPancakeRouter01BNB.sol";

interface IPancakeRouter02BNB is IPancakeRouter01BNB {
    function removeLiquidityBNBSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountBNB);

    function removeLiquidityBNBWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountBNB);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactBNBForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForBNBSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IWETH {
    function deposit() external payable;

    function transfer(address to, uint256 value) external returns (bool);

    function withdraw(uint256) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

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

pragma solidity ^0.8.0;

import "../IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

{
  "remappings": [],
  "optimizer": {
    "enabled": true,
    "runs": 200
  },
  "evmVersion": "berlin",
  "libraries": {
    "/Users/tepnik/Desktop/ydragon-contracts/contracts/lib/AssetLib.sol": {
      "AssetLib": "0x7508C726dD8246EF2fBD205323A58474A5f7DA5D"
    }
  },
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