// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/utils/Create2Upgradeable.sol";

import "./compound/ErrorReporter.sol";
import "./external/compound/IComptroller.sol";
import "./compound/CErc20Delegator.sol";
import "./compound/CErc20PluginDelegate.sol";
import "./midas/SafeOwnableUpgradeable.sol";
import "./utils/PatchedStorage.sol";
import "./oracles/BasePriceOracle.sol";
import { CTokenExtensionInterface } from "./compound/CTokenInterfaces.sol";
import { DiamondExtension, DiamondBase } from "./midas/DiamondExtension.sol";

/**
 * @title FuseFeeDistributor
 * @author David Lucid <david@rari.capital> (https://github.com/davidlucid)
 * @notice FuseFeeDistributor controls and receives protocol fees from Fuse pools and relays admin actions to Fuse pools.
 */
contract FuseFeeDistributor is SafeOwnableUpgradeable, PatchedStorage {
  using AddressUpgradeable for address;
  using SafeERC20Upgradeable for IERC20Upgradeable;

  /**
   * @dev Initializer that sets initial values of state variables.
   * @param _defaultInterestFeeRate The default proportion of Fuse pool interest taken as a protocol fee (scaled by 1e18).
   */
  function initialize(uint256 _defaultInterestFeeRate) public initializer {
    require(_defaultInterestFeeRate <= 1e18, "Interest fee rate cannot be more than 100%.");
    __SafeOwnable_init(msg.sender);
    defaultInterestFeeRate = _defaultInterestFeeRate;
    maxSupplyEth = type(uint256).max;
    maxUtilizationRate = type(uint256).max;
  }

  /**
   * @notice The proportion of Fuse pool interest taken as a protocol fee (scaled by 1e18).
   */
  uint256 public defaultInterestFeeRate;

  /**
   * @dev Sets the default proportion of Fuse pool interest taken as a protocol fee.
   * @param _defaultInterestFeeRate The default proportion of Fuse pool interest taken as a protocol fee (scaled by 1e18).
   */
  function _setDefaultInterestFeeRate(uint256 _defaultInterestFeeRate) external onlyOwner {
    require(_defaultInterestFeeRate <= 1e18, "Interest fee rate cannot be more than 100%.");
    defaultInterestFeeRate = _defaultInterestFeeRate;
  }

  /**
   * @dev Withdraws accrued fees on interest.
   * @param erc20Contract The ERC20 token address to withdraw. Set to the zero address to withdraw ETH.
   */
  function _withdrawAssets(address erc20Contract) external {
    if (erc20Contract == address(0)) {
      uint256 balance = address(this).balance;
      require(balance > 0, "No balance available to withdraw.");
      (bool success, ) = owner().call{ value: balance }("");
      require(success, "Failed to transfer ETH balance to msg.sender.");
    } else {
      IERC20Upgradeable token = IERC20Upgradeable(erc20Contract);
      uint256 balance = token.balanceOf(address(this));
      require(balance > 0, "No token balance available to withdraw.");
      token.safeTransfer(owner(), balance);
    }
  }

  /**
   * @dev Minimum borrow balance (in ETH) per user per Fuse pool asset (only checked on new borrows, not redemptions).
   */
  uint256 public minBorrowEth;

  /**
   * @dev Maximum supply balance (in ETH) per user per Fuse pool asset.
   * No longer used as of `Rari-Capital/compound-protocol` version `fuse-v1.1.0`.
   */
  uint256 public maxSupplyEth;

  /**
   * @dev Maximum utilization rate (scaled by 1e18) for Fuse pool assets (only checked on new borrows, not redemptions).
   * No longer used as of `Rari-Capital/compound-protocol` version `fuse-v1.1.0`.
   */
  uint256 public maxUtilizationRate;

  /**
   * @dev Sets the proportion of Fuse pool interest taken as a protocol fee.
   * @param _minBorrowEth Minimum borrow balance (in ETH) per user per Fuse pool asset (only checked on new borrows, not redemptions).
   * @param _maxSupplyEth Maximum supply balance (in ETH) per user per Fuse pool asset.
   * @param _maxUtilizationRate Maximum utilization rate (scaled by 1e18) for Fuse pool assets (only checked on new borrows, not redemptions).
   */
  function _setPoolLimits(
    uint256 _minBorrowEth,
    uint256 _maxSupplyEth,
    uint256 _maxUtilizationRate
  ) external onlyOwner {
    minBorrowEth = _minBorrowEth;
    maxSupplyEth = _maxSupplyEth;
    maxUtilizationRate = _maxUtilizationRate;
  }

  function getMinBorrowEth(CTokenInterface _ctoken) public view returns (uint256) {
    (, , uint256 borrowBalance, ) = _ctoken.getAccountSnapshot(_msgSender());
    if (borrowBalance == 0) return minBorrowEth;
    IComptroller comptroller = IComptroller(address(_ctoken.comptroller()));
    BasePriceOracle oracle = BasePriceOracle(address(comptroller.oracle()));
    uint256 underlyingPriceEth = oracle.price(CErc20Interface(address(_ctoken)).underlying());
    uint256 underlyingDecimals = _ctoken.decimals();
    uint256 borrowBalanceEth = (underlyingPriceEth * borrowBalance) / 10**underlyingDecimals;
    if (borrowBalanceEth > minBorrowEth) {
      return 0;
    }
    return minBorrowEth - borrowBalanceEth;
  }

  /**
   * @dev Receives ETH fees.
   */
  receive() external payable {}

  /**
   * @dev Sends data to a contract.
   * @param targets The contracts to which `data` will be sent.
   * @param data The data to be sent to each of `targets`.
   */
  function _callPool(address[] calldata targets, bytes[] calldata data) external onlyOwner {
    require(targets.length > 0 && targets.length == data.length, "Array lengths must be equal and greater than 0.");
    for (uint256 i = 0; i < targets.length; i++) targets[i].functionCall(data[i]);
  }

  /**
   * @dev Sends data to a contract.
   * @param targets The contracts to which `data` will be sent.
   * @param data The data to be sent to each of `targets`.
   */
  function _callPool(address[] calldata targets, bytes calldata data) external onlyOwner {
    require(targets.length > 0, "No target addresses specified.");
    for (uint256 i = 0; i < targets.length; i++) targets[i].functionCall(data);
  }

  /**
   * @dev Deploys a CToken for an underlying ERC20
   * @param constructorData Encoded construction data for `CToken initialize()`
   */
  function deployCErc20(bytes calldata constructorData) external returns (address) {
    // Make sure comptroller == msg.sender
    (address underlying, address comptroller) = abi.decode(constructorData[0:64], (address, address));
    require(comptroller == msg.sender, "Comptroller is not sender.");

    // Deploy CErc20Delegator using msg.sender, underlying, and block.number as a salt
    bytes32 salt = keccak256(abi.encodePacked(msg.sender, underlying, ++marketsCounter));

    bytes memory cErc20DelegatorCreationCode = abi.encodePacked(type(CErc20Delegator).creationCode, constructorData);
    address proxy = Create2Upgradeable.deploy(0, salt, cErc20DelegatorCreationCode);

    return proxy;
  }

  /**
   * @dev Whitelisted Comptroller implementation contract addresses for each existing implementation.
   */
  mapping(address => mapping(address => bool)) public comptrollerImplementationWhitelist;

  /**
   * @dev Adds/removes Comptroller implementations to the whitelist.
   * @param oldImplementations The old `Comptroller` implementation addresses to upgrade from for each `newImplementations` to upgrade to.
   * @param newImplementations Array of `Comptroller` implementations to be whitelisted/unwhitelisted.
   * @param statuses Array of whitelist statuses corresponding to `implementations`.
   */
  function _editComptrollerImplementationWhitelist(
    address[] calldata oldImplementations,
    address[] calldata newImplementations,
    bool[] calldata statuses
  ) external onlyOwner {
    require(
      newImplementations.length > 0 &&
        newImplementations.length == oldImplementations.length &&
        newImplementations.length == statuses.length,
      "No Comptroller implementations supplied or array lengths not equal."
    );
    for (uint256 i = 0; i < newImplementations.length; i++)
      comptrollerImplementationWhitelist[oldImplementations[i]][newImplementations[i]] = statuses[i];
  }

  /**
   * @dev Whitelisted CErc20Delegate implementation contract addresses and `allowResign` values for each existing implementation.
   */
  mapping(address => mapping(address => mapping(bool => bool))) public cErc20DelegateWhitelist;

  /**
   * @dev Adds/removes CErc20Delegate implementations to the whitelist.
   * @param oldImplementations The old `CErc20Delegate` implementation addresses to upgrade from for each `newImplementations` to upgrade to.
   * @param newImplementations Array of `CErc20Delegate` implementations to be whitelisted/unwhitelisted.
   * @param allowResign Array of `allowResign` values corresponding to `newImplementations` to be whitelisted/unwhitelisted.
   * @param statuses Array of whitelist statuses corresponding to `newImplementations`.
   */
  function _editCErc20DelegateWhitelist(
    address[] calldata oldImplementations,
    address[] calldata newImplementations,
    bool[] calldata allowResign,
    bool[] calldata statuses
  ) external onlyOwner {
    require(
      newImplementations.length > 0 &&
        newImplementations.length == oldImplementations.length &&
        newImplementations.length == allowResign.length &&
        newImplementations.length == statuses.length,
      "No CErc20Delegate implementations supplied or array lengths not equal."
    );
    for (uint256 i = 0; i < newImplementations.length; i++)
      cErc20DelegateWhitelist[oldImplementations[i]][newImplementations[i]][allowResign[i]] = statuses[i];
  }

  /**
   * @dev Whitelisted CEtherDelegate implementation contract addresses and `allowResign` values for each existing implementation.
   */
  /// keep this in the storage to not break the layout
  mapping(address => mapping(address => mapping(bool => bool))) public cEtherDelegateWhitelist;

  /**
   * @dev Latest Comptroller implementation for each existing implementation.
   */
  mapping(address => address) internal _latestComptrollerImplementation;

  /**
   * @dev Latest Comptroller implementation for each existing implementation.
   */
  function latestComptrollerImplementation(address oldImplementation) external view returns (address) {
    return
      _latestComptrollerImplementation[oldImplementation] != address(0)
        ? _latestComptrollerImplementation[oldImplementation]
        : oldImplementation;
  }

  /**
   * @dev Sets the latest `Comptroller` upgrade implementation address.
   * @param oldImplementation The old `Comptroller` implementation address to upgrade from.
   * @param newImplementation Latest `Comptroller` implementation address.
   */
  function _setLatestComptrollerImplementation(address oldImplementation, address newImplementation)
    external
    onlyOwner
  {
    _latestComptrollerImplementation[oldImplementation] = newImplementation;
  }

  struct CDelegateUpgradeData {
    address implementation;
    bool allowResign;
    bytes becomeImplementationData;
  }

  /**
   * @dev Latest CErc20Delegate implementation for each existing implementation.
   */
  mapping(address => CDelegateUpgradeData) public _latestCErc20Delegate;

  /**
   * @dev Latest CEtherDelegate implementation for each existing implementation.
   */
  /// keep this in the storage to not break the layout
  mapping(address => CDelegateUpgradeData) public _latestCEtherDelegate;

  /**
   * @dev Latest CErc20Delegate implementation for each existing implementation.
   */
  function latestCErc20Delegate(address oldImplementation)
    external
    view
    returns (
      address,
      bool,
      bytes memory
    )
  {
    CDelegateUpgradeData memory data = _latestCErc20Delegate[oldImplementation];
    bytes memory emptyBytes;
    return
      data.implementation != address(0)
        ? (data.implementation, data.allowResign, data.becomeImplementationData)
        : (oldImplementation, false, emptyBytes);
  }

  /**
   * @dev Sets the latest `CErc20Delegate` upgrade implementation address and data.
   * @param oldImplementation The old `CErc20Delegate` implementation address to upgrade from.
   * @param newImplementation Latest `CErc20Delegate` implementation address.
   * @param allowResign Whether or not `resignImplementation` should be called on the old implementation before upgrade.
   * @param becomeImplementationData Data passed to the new implementation via `becomeImplementation` after upgrade.
   */
  function _setLatestCErc20Delegate(
    address oldImplementation,
    address newImplementation,
    bool allowResign,
    bytes calldata becomeImplementationData
  ) external onlyOwner {
    _latestCErc20Delegate[oldImplementation] = CDelegateUpgradeData(
      newImplementation,
      allowResign,
      becomeImplementationData
    );
  }

  /**
   * @notice Maps Unitroller (Comptroller proxy) addresses to the proportion of Fuse pool interest taken as a protocol fee (scaled by 1e18).
   * @dev A value of 0 means unset whereas a negative value means 0.
   */
  mapping(address => int256) public customInterestFeeRates;

  /**
   * @dev used as salt for the creation of new markets
   */
  uint256 public marketsCounter;

  /**
   * @dev Latest Plugin implementation for each existing implementation.
   */
  mapping(address => address) public _latestPluginImplementation;

  /**
   * @dev Whitelisted Plugin implementation contract addresses for each existing implementation.
   */
  mapping(address => mapping(address => bool)) public pluginImplementationWhitelist;

  /**
   * @dev Adds/removes plugin implementations to the whitelist.
   * @param oldImplementations The old plugin implementation addresses to upgrade from for each `newImplementations` to upgrade to.
   * @param newImplementations Array of plugin implementations to be whitelisted/unwhitelisted.
   * @param statuses Array of whitelist statuses corresponding to `implementations`.
   */
  function _editPluginImplementationWhitelist(
    address[] calldata oldImplementations,
    address[] calldata newImplementations,
    bool[] calldata statuses
  ) external onlyOwner {
    require(
      newImplementations.length > 0 &&
        newImplementations.length == oldImplementations.length &&
        newImplementations.length == statuses.length,
      "No plugin implementations supplied or array lengths not equal."
    );
    for (uint256 i = 0; i < newImplementations.length; i++)
      pluginImplementationWhitelist[oldImplementations[i]][newImplementations[i]] = statuses[i];
  }

  /**
   * @dev Latest Plugin implementation for each existing implementation.
   */
  function latestPluginImplementation(address oldImplementation) external view returns (address) {
    return
      _latestPluginImplementation[oldImplementation] != address(0)
        ? _latestPluginImplementation[oldImplementation]
        : oldImplementation;
  }

  /**
   * @dev Sets the latest plugin upgrade implementation address.
   * @param oldImplementation The old plugin implementation address to upgrade from.
   * @param newImplementation Latest plugin implementation address.
   */
  function _setLatestPluginImplementation(address oldImplementation, address newImplementation) external onlyOwner {
    _latestPluginImplementation[oldImplementation] = newImplementation;
  }

  /**
   * @dev Upgrades a plugin of a CErc20PluginDelegate market to the latest implementation
   * @param cDelegator the proxy address
   * @return if the plugin was upgraded or not
   */
  function _upgradePluginToLatestImplementation(address cDelegator) external onlyOwner returns (bool) {
    CErc20PluginDelegate market = CErc20PluginDelegate(cDelegator);

    address oldPluginAddress = address(market.plugin());
    market._updatePlugin(_latestPluginImplementation[oldPluginAddress]);
    address newPluginAddress = address(market.plugin());

    return newPluginAddress != oldPluginAddress;
  }

  /**
   * @notice Returns the proportion of Fuse pool interest taken as a protocol fee (scaled by 1e18).
   */
  function interestFeeRate() external view returns (uint256) {
    (bool success, bytes memory data) = msg.sender.staticcall(abi.encodeWithSignature("comptroller()"));

    if (success && data.length == 32) {
      address comptroller = abi.decode(data, (address));
      int256 customRate = customInterestFeeRates[comptroller];
      if (customRate > 0) return uint256(customRate);
      if (customRate < 0) return 0;
    }

    return defaultInterestFeeRate;
  }

  /**
   * @dev Sets the proportion of Fuse pool interest taken as a protocol fee.
   * @param comptroller The Unitroller (Comptroller proxy) address.
   * @param rate The proportion of Fuse pool interest taken as a protocol fee (scaled by 1e18).
   */
  function _setCustomInterestFeeRate(address comptroller, int256 rate) external onlyOwner {
    require(rate <= 1e18, "Interest fee rate cannot be more than 100%.");
    customInterestFeeRates[comptroller] = rate;
  }

  mapping(address => DiamondExtension[]) public comptrollerExtensions;

  function getComptrollerExtensions(address comptroller) external view returns (DiamondExtension[] memory) {
    return comptrollerExtensions[comptroller];
  }

  function _setComptrollerExtensions(address comptroller, DiamondExtension[] calldata extensions) external onlyOwner {
    comptrollerExtensions[comptroller] = extensions;
  }

  function _registerComptrollerExtension(
    address payable pool,
    DiamondExtension extensionToAdd,
    DiamondExtension extensionToReplace
  ) external onlyOwner {
    DiamondBase(pool)._registerExtension(extensionToAdd, extensionToReplace);
  }

  mapping(address => DiamondExtension[]) public cErc20DelegateExtensions;

  function getCErc20DelegateExtensions(address cErc20Delegate) external view returns (DiamondExtension[] memory) {
    return cErc20DelegateExtensions[cErc20Delegate];
  }

  function _setCErc20DelegateExtensions(address cErc20Delegate, DiamondExtension[] calldata extensions)
    external
    onlyOwner
  {
    cErc20DelegateExtensions[cErc20Delegate] = extensions;
  }

  function autoUpgradePool(IComptroller pool) external onlyOwner {
    ICToken[] memory markets = pool.getAllMarkets();
    bool autoImplOnBefore = pool.autoImplementation();
    pool._toggleAutoImplementations(true);

    // auto upgrade the pool
    pool.enterMarkets(new address[](0));

    for (uint8 i = 0; i < markets.length; i++) {
      address marketAddress = address(markets[i]);
      // auto upgrade the market
      CTokenExtensionInterface(marketAddress).accrueInterest();
    }

    if (!autoImplOnBefore) pool._toggleAutoImplementations(false);
  }

  function toggleAutoimplementations(IComptroller pool, bool enabled) external onlyOwner {
    pool._toggleAutoImplementations(enabled);
  }
}
