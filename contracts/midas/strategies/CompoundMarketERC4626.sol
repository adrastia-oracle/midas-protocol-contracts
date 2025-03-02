// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "./MidasERC4626.sol";
import { ICErc20 } from "../../external/compound/ICErc20.sol";
import { IComptroller } from "../../external/compound/IComptroller.sol";

import "openzeppelin-contracts-upgradeable/contracts/interfaces/IERC4626Upgradeable.sol";
import "../../external/angle/IGenericLender.sol";
import "../vault/OptimizedVaultsRegistry.sol";

contract CompoundMarketERC4626 is MidasERC4626, IGenericLender {
  ICErc20 public market;
  uint256 public blocksPerYear;
  OptimizedVaultsRegistry public registry;

  event ClaimedVaultRewards(address indexed rewardToken, address indexed vault, uint256 amount);

  modifier onlyRegisteredVaults() {
    OptimizedAPRVaultBase[] memory vaults = registry.getAllVaults();
    bool isMsgSender = false;
    for (uint256 i = 0; i < vaults.length; i++) {
      if (msg.sender == address(vaults[i])) {
        isMsgSender = true;
        break;
      }
    }
    require(isMsgSender, "!caller not a vault");
    _;
  }

  constructor() {
    _disableInitializers();
  }

  function initialize(
    ICErc20 market_,
    uint256 blocksPerYear_,
    OptimizedVaultsRegistry registry_
  ) public initializer {
    __MidasER4626_init(ERC20Upgradeable(market_.underlying()));
    market = market_;
    blocksPerYear = blocksPerYear_;
    registry = registry_;
  }

  function reinitialize(address registry_) public onlyOwnerOrAdmin {
    registry = OptimizedVaultsRegistry(registry_);
  }

  function lenderName() public view returns (string memory) {
    return string(bytes.concat("Midas Optimized ", bytes(name())));
  }

  function totalAssets() public view override returns (uint256) {
    // TODO consider making the ctoken balanceOfUnderlying fn a view fn
    return (market.balanceOf(address(this)) * market.exchangeRateHypothetical()) / 1e18;
  }

  function balanceOfUnderlying(address account) public view returns (uint256) {
    return convertToAssets(balanceOf(account));
  }

  function afterDeposit(uint256 amount, uint256) internal override onlyRegisteredVaults {
    ERC20Upgradeable(asset()).approve(address(market), amount);
    require(market.mint(amount) == 0, "deposit to market failed");
  }

  function beforeWithdraw(uint256 amount, uint256) internal override onlyRegisteredVaults {
    require(market.redeemUnderlying(amount) == 0, "redeem from market failed");
  }

  function aprAfterDeposit(uint256 amount) public view returns (uint256) {
    return market.supplyRatePerBlockAfterDeposit(amount) * blocksPerYear;
  }

  function aprAfterWithdraw(uint256 amount) public view override returns (uint256) {
    return market.supplyRatePerBlockAfterWithdraw(amount) * blocksPerYear;
  }

  function emergencyWithdrawAndPause() external override {
    require(msg.sender == owner() || msg.sender == address(registry), "not owner or vaults registry");
    require(market.redeemUnderlying(type(uint256).max) == 0, "redeem all failed");
    _pause();
  }

  function unpause() external override onlyOwner {
    _unpause();
  }

  /*------------------------------------------------------------
                        IGenericLender FNs
    ------------------------------------------------------------*/

  /// @notice Returns an estimation of the current Annual Percentage Rate on the lender
  function apr() public view override returns (uint256) {
    return market.supplyRatePerBlock() * blocksPerYear;
  }

  /// @notice Returns an estimation of the current Annual Percentage Rate weighted by the assets under
  /// management of the lender
  function weightedApr() external view returns (uint256) {
    return (apr() * totalAssets()) / 1e18;
  }

  /// @notice Returns an estimation of the hypothetical Annual Percentage Rate weighted by the assets under
  /// management of the lender plus the amount, if deposited
  function weightedAprAfterDeposit(uint256 amount) public view returns (uint256) {
    return (aprAfterDeposit(amount) * (totalAssets() + amount)) / 1e18;
  }

  /// @notice Withdraws a given amount from lender
  /// @param amount The amount the caller wants to withdraw
  /// @return Amount actually withdrawn
  function withdraw(uint256 amount) public override returns (uint256) {
    withdraw(amount, msg.sender, msg.sender);
    return amount;
  }

  /// @notice Withdraws as much as possible from the lending platform
  /// @return Whether everything was withdrawn or not
  function withdrawAll() public override returns (bool) {
    return withdraw(maxWithdraw(msg.sender), msg.sender, msg.sender) > 0;
  }

  /// @notice Removes tokens from this Strategy that are not the type of tokens
  /// managed by this Strategy. This may be used in case of accidentally
  /// sending the wrong kind of token to this Strategy.
  ///
  /// @param _token The token to transfer out of this poolManager.
  /// @param to Address to send the tokens to.
  function sweep(address _token, address to) public onlyOwner {
    require(_token != asset(), "!asset");

    IERC20Upgradeable token = IERC20Upgradeable(_token);
    token.transfer(to, token.balanceOf(address(this)));
  }

  function claimRewards() public onlyRegisteredVaults {
    IComptroller pool = IComptroller(market.comptroller());
    address[] memory poolFlywheels = pool.getRewardsDistributors();

    for (uint256 j = 0; j < poolFlywheels.length; j++) {
      MidasFlywheel flywheel = MidasFlywheel(poolFlywheels[j]);
      ERC20 rewardToken = flywheel.rewardToken();

      // accrue and claim the rewards
      flywheel.accrue(ERC20(address(market)), address(this));
      flywheel.claimRewards(address(this));

      uint256 totalRewards = rewardToken.balanceOf(address(this));
      // avoid rounding errors for too little amounts
      if (totalRewards > 1000) {
        // the rewards that are in the underlying asset are autocompounded
        if (address(rewardToken) == address(asset())) {
          afterDeposit(totalRewards, 0);
        } else {
          // redistribute the claimed rewards among the vaults
          OptimizedAPRVaultBase[] memory vaults = registry.getAllVaults();
          for (uint256 i = 0; i < vaults.length; i++) {
            address vaultAddress = address(vaults[i]);
            uint256 vaultSharesInAdapter = balanceOf(vaultAddress);
            uint256 vaultShareOfRewards = (vaultSharesInAdapter * totalRewards) / totalSupply();
            if (vaultShareOfRewards > 0) {
              rewardToken.transfer(vaultAddress, vaultShareOfRewards);
              emit ClaimedVaultRewards(address(rewardToken), vaultAddress, vaultShareOfRewards);
            }
          }
        }
      }
    }
  }
}
