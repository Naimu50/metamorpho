// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.21;

import {IMetaMorpho} from "./interfaces/IMetaMorpho.sol";

import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MetaMorpho} from "./MetaMorpho.sol";

contract MetaMorphoFactory {
    /* IMMUTABLES */

    address public immutable METAMORPHO_IMPL;

    /* STORAGE */

    mapping(address => bool) public isMetaMorpho;

    /* CONSTRCUTOR */

    constructor(address implementation) {
        if (implementation == address(0)) revert ErrorsLib.ZeroAddress();

        METAMORPHO_IMPL = implementation;
    }

    /* EXTERNAL */

    function createMetaMorpho(
        address initialOwner,
        uint256 initialTimelock,
        address asset,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (MetaMorpho metaMorpho) {
        metaMorpho = MetaMorpho(Clones.cloneDeterministic(METAMORPHO_IMPL, salt));

        metaMorpho.initialize(initialOwner, initialTimelock, asset, name, symbol);

        isMetaMorpho[address(metaMorpho)] = true;

        emit EventsLib.CreateMetaMorpho(
            address(metaMorpho), msg.sender, initialOwner, initialTimelock, asset, name, symbol, salt
        );
    }
}