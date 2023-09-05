// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.21;

import {MarketAllocation, ISupplyVault} from "./interfaces/ISupplyVault.sol";
import {Id, MarketParams, Market, IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {WAD} from "@morpho-blue/libraries/MathLib.sol";
import {UtilsLib} from "@morpho-blue/libraries/UtilsLib.sol";
import {VaultMarket, VaultMarketConfig, ConfigSet, ConfigSetLib} from "./libraries/ConfigSetLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    IERC20,
    ERC20,
    ERC4626,
    Context,
    Math,
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract SupplyVault is ERC4626, Ownable2Step, ISupplyVault {
    using Math for uint256;
    using UtilsLib for uint256;
    using ConfigSetLib for ConfigSet;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    IMorpho internal immutable _MORPHO;

    mapping(address => bool) public isRiskManager;
    mapping(address => bool) public isAllocator;

    Id[] public orderedSupply;
    Id[] public orderedWithdraw;

    uint96 fee;
    address feeRecipient;

    /// @dev Stores the total assets owned by this vault when the fee was last accrued.
    uint256 lastTotalAssets;

    ConfigSet private _config;

    /* CONSTRUCTORS */

    constructor(address morpho, IERC20 _asset, string memory _name, string memory _symbol)
        ERC4626(_asset)
        ERC20(_name, _symbol)
    {
        _MORPHO = IMorpho(morpho);

        SafeERC20.safeApprove(_asset, morpho, type(uint256).max);
    }

    /* MODIFIERS */

    modifier onlyRiskManager() {
        require(isRiskManager[_msgSender()], ErrorsLib.NOT_RISK_MANAGER);

        _;
    }

    modifier onlyAllocator() {
        require(isAllocator[_msgSender()], ErrorsLib.NOT_ALLOCATOR);

        _;
    }

    /* ONLY OWNER FUNCTIONS */

    function setIsRiskManager(address newRiskManager, bool newIsRiskManager) external onlyOwner {
        isRiskManager[newRiskManager] = newIsRiskManager;

        emit EventsLib.SetIsRiskManager(newRiskManager, newIsRiskManager);
    }

    function setIsAllocator(address newAllocator, bool newIsAllocator) external onlyOwner {
        isAllocator[newAllocator] = newIsAllocator;

        emit EventsLib.SetIsAllocator(newAllocator, newIsAllocator);
    }

    function setFee(uint256 newFee) external onlyOwner {
        require(newFee != fee, ErrorsLib.ALREADY_SET);
        require(newFee <= WAD, ErrorsLib.MAX_FEE_EXCEEDED);

        // Accrue interest using the previous fee set before changing it.
        _accrueFee();

        // Safe "unchecked" cast because newFee <= WAD.
        fee = uint96(newFee);

        emit EventsLib.SetFee(newFee);

        if (newFee != 0) lastTotalAssets = totalAssets();
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

        // Accrue interest to the previous fee recipient set before changing it.
        _accrueFee();

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);

        if (newFeeRecipient != address(0)) lastTotalAssets = totalAssets();
    }

    /* ONLY RISK MANAGER FUNCTIONS */

    function setConfig(MarketParams memory marketParams, VaultMarketConfig calldata marketConfig)
        external
        onlyRiskManager
    {
        require(marketParams.borrowableToken == asset(), ErrorsLib.INCONSISTENT_ASSET);

        Id id = marketParams.id();
        // Add market to the ordered lists if the market is added.
        if (!_config.contains(id)) {
            orderedSupply.push(id);
            orderedWithdraw.push(id);
        }

        require(_config.update(marketParams, marketConfig), ErrorsLib.CONFIG_UDPATE_FAILED);
    }

    function disableMarket(Id id) external onlyRiskManager {
        _removeFromOrderedMarkets(orderedSupply, id);
        _removeFromOrderedMarkets(orderedWithdraw, id);

        require(_config.remove(id), ErrorsLib.DISABLE_MARKET_FAILED);
    }

    function _removeFromOrderedMarkets(Id[] storage orderedMarkets, Id id) internal {
        uint256 length = _config.length();

        for (uint256 i; i < length; ++i) {
            // Do not conserve the order of the markets.
            if (orderedMarkets[i] == id) {
                orderedMarkets[i] = orderedMarkets[length - 1];
                orderedMarkets.pop();

                return;
            }
        }
    }

    function setOrderedSupply(Id[] calldata newOrderedSupply) external onlyRiskManager {
        _checkOrderedMarkets(orderedSupply, newOrderedSupply);

        orderedSupply = newOrderedSupply;
    }

    function setOrderedWithdraw(Id[] calldata newOrderedWithdraw) external onlyRiskManager {
        _checkOrderedMarkets(orderedWithdraw, newOrderedWithdraw);

        orderedWithdraw = newOrderedWithdraw;
    }

    function _checkOrderedMarkets(Id[] storage oldOrderedMarkets, Id[] calldata newOrderedMarkets) internal {
        uint256 length = newOrderedMarkets.length;

        require(length == oldOrderedMarkets.length, ErrorsLib.INVALID_LENGTH);

        for (uint256 i; i < length; ++i) {
            require(_config.contains(newOrderedMarkets[i]), ErrorsLib.INVALID_ORDERED_MARKETS);
        }
    }

    /// @dev MUST NOT revert on a market.
    function _depositOrdered(uint256 assets) internal returns (uint256) {
        uint256 i;
        uint256 length = orderedSupply.length;

        while (assets > 0 && i < length) {
            Id id = orderedSupply[i];
            ++i;

            VaultMarketConfig storage marketConfig = _market(id).config;
            uint256 cap = marketConfig.cap;
            uint256 toDeposit;

            if (cap > 0) {
                uint256 currentSupply = _supplyBalance(id);
                uint256 newSupply = assets + currentSupply;

                if (newSupply > cap) toDeposit = cap - currentSupply;
                else toDeposit = assets;
            }

            bytes memory encodedCall =
                abi.encodeCall(_MORPHO.supply.selector, marketParams, toDeposit, 0, address(this), hex"");
            (bool success,) = address(_MORPHO).call(encodedCall);

            if (success) assets -= toDeposit;
        }

        return assets;
    }

    /// @dev MUST NOT revert on a market.
    function _withdrawOrdered(uint256 assets, bool skipCalls) internal returns (uint256) {
        uint256 i;
        uint256 length = orderedWithdraw.length;

        while (assets > 0 && i < length) {
            Id id = orderedWithdraw[i];
            ++i;

            (uint256 totalSupply,, uint256 totalBorrow,) = _MORPHO.expectedMarketBalances(id);
            uint256 available = totalBorrow - totalSupply;

            if (available > 0) {
                uint256 toWithdraw = UtilsLib.min(available, assets);

                bytes memory encodedCall =
                    abi.encodeCall(_MORPHO.withdraw.selector, marketParams, toWithdraw, 0, address(this), address(this));

                (bool success,) =
                    skipCalls ? address(_MORPHO).staticcall(encodedCall) : address(_MORPHO).call(encodedCall);

                if (success) assets -= toWithdraw;
            }
        }

        return assets;
    }

    /* ONLY ALLOCATOR FUNCTIONS */

    function reallocate(MarketAllocation[] calldata withdrawn, MarketAllocation[] calldata supplied)
        external
        onlyAllocator
    {
        _reallocate(withdrawn, supplied);
    }

    /* PUBLIC */

    function config(Id id) public view returns (VaultMarketConfig memory) {
        return _market(id).config;
    }

    /* ERC4626 */

    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        _accruedFeeShares();

        return _withdrawOrdered(super.maxWithdraw(owner), true);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return _convertToShares(maxWithdraw(owner), Math.Rounding.Down);
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _accrueFee();

        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        _accrueFee();

        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        returns (uint256 shares)
    {
        _accrueFee();

        // Do not call expensive `maxWithdraw` and optimistically withdraw assets.

        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256 assets) {
        _accrueFee();

        // Do not call expensive `maxRedeem` and optimistically redeem shares.

        assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function totalAssets() public view override returns (uint256 assets) {
        uint256 nbMarkets = _config.length();

        for (uint256 i; i < nbMarkets; ++i) {
            MarketParams memory marketParams = _config.at(i);

            assets += _supplyBalance(marketParams);
        }

        assets += ERC20(asset()).balanceOf(address(this));
    }

    /// @dev Used in mint or deposit to deposit the underlying asset to Blue markets.
    function _deposit(address caller, address owner, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, owner, assets, shares);

        require(_depositOrdered(assets) == assets, ErrorsLib.DEPOSIT_ORDERED_FAILED);
    }

    /// @dev Used in redeem or withdraw to withdraw the underlying asset from Blue markets.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        require(_withdrawOrdered(assets, false) == assets, ErrorsLib.WITHDRAW_ORDERED_FAILED);

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* INTERNAL */

    function _market(Id id) internal view returns (VaultMarket storage) {
        require(_config.contains(id), ErrorsLib.UNAUTHORIZED_MARKET);

        return _config.getMarket(id);
    }

    function _supplyBalance(MarketParams memory marketParams) internal view returns (uint256) {
        return _MORPHO.expectedSupplyBalance(marketParams, address(this));
    }

    function _supplyMorpho(MarketAllocation memory allocation) internal {
        Id id = allocation.marketParams.id();
        VaultMarketConfig storage marketConfig = _market(id).config;

        uint256 cap = marketConfig.cap;
        if (cap > 0) {
            uint256 newSupply = allocation.assets + _supplyBalance(allocation.marketParams);

            require(newSupply <= cap, ErrorsLib.SUPPLY_CAP_EXCEEDED);
        }

        _MORPHO.supply(allocation.marketParams, allocation.assets, 0, address(this), hex"");
    }

    function _reallocate(MarketAllocation[] memory withdrawn, MarketAllocation[] memory supplied) internal {
        uint256 nbWithdrawn = withdrawn.length;

        for (uint256 i; i < nbWithdrawn; ++i) {
            MarketAllocation memory allocation = withdrawn[i];

            _MORPHO.withdraw(allocation.marketParams, allocation.assets, 0, address(this), address(this));
        }

        uint256 nbSupplied = supplied.length;

        for (uint256 i; i < nbSupplied; ++i) {
            _supplyMorpho(supplied[i]); // TODO: should we check config if supplied is provided by an onchain strategy?
        }
    }

    function _accrueFee() internal {
        if (fee == 0 || feeRecipient == address(0)) return;

        (uint256 newTotalAssets, uint256 feeShares) = _accruedFeeShares();

        lastTotalAssets = newTotalAssets;

        if (feeShares != 0) _mint(feeRecipient, feeShares);

        emit EventsLib.AccrueFee(newTotalAssets, feeShares);
    }

    function _accruedFeeShares() internal view returns (uint256 newTotalAssets, uint256 feeShares) {
        newTotalAssets = totalAssets();
        uint256 totalInterest = newTotalAssets.zeroFloorSub(lastTotalAssets);

        if (totalInterest != 0) {
            uint256 feeAmount = totalInterest.mulDiv(fee, WAD);
            // The fee amount is subtracted from the total assets in this calculation to compensate for the fact
            // that total assets is already increased by the total interest (including the fee amount).
            feeShares = feeAmount.mulDiv(
                totalSupply() + 10 ** _decimalsOffset(), newTotalAssets - feeAmount + 1, Math.Rounding.Down
            );
        }
    }
}