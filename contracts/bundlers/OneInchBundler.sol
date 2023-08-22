// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.21;

import {I1InchAggregationRouterV5} from "./interfaces/I1InchAggregationRouterV5.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {SafeTransferLib, ERC20} from "@solmate/utils/SafeTransferLib.sol";

import {BaseBundler} from "./BaseBundler.sol";

abstract contract OneInchBundler is BaseBundler {
    using SafeTransferLib for ERC20;

    I1InchAggregationRouterV5 public immutable ONE_INCH_ROUTER;

    constructor(address router) {
        require(router != address(0), ErrorsLib.ZERO_ADDRESS);

        ONE_INCH_ROUTER = I1InchAggregationRouterV5(router);
    }

    /* ACTIONS */

    /// @dev Triggers a swap on 1inch with parameters calculated by the 1inch API using compatibility mode.
    function oneInchSwap(address executor, I1InchAggregationRouterV5.SwapDescription calldata desc, bytes calldata data)
        external
    {
        ERC20(desc.srcToken).safeApprove(address(ONE_INCH_ROUTER), desc.amount);

        ONE_INCH_ROUTER.swap(executor, desc, hex"", data);
    }
}
