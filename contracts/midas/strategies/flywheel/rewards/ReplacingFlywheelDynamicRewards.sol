// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import { FlywheelDynamicRewards } from "flywheel-v2/rewards/FlywheelDynamicRewards.sol";
import { BaseFlywheelRewards } from "flywheel-v2/rewards/BaseFlywheelRewards.sol";
import { FlywheelCore } from "flywheel-v2/FlywheelCore.sol";
import { Auth, Authority } from "solmate/auth/Auth.sol";
import { SafeTransferLib, ERC20 } from "solmate/utils/SafeTransferLib.sol";

interface ICERC20 {
  function plugin() external returns (address);
}

interface IPlugin {
  function claimRewards() external;
}

contract ReplacingFlywheelDynamicRewards is FlywheelDynamicRewards {
  using SafeTransferLib for ERC20;

  FlywheelCore public replacedFlywheel;

    constructor(
      FlywheelCore _replacedFlywheel,
      FlywheelCore _flywheel,
      uint32 _cycleLength
    ) FlywheelDynamicRewards(_flywheel, _cycleLength) {
      replacedFlywheel = _replacedFlywheel;
      // rewardToken.safeApprove(address(_replacedFlywheel), type(uint256).max);
    }

  function getNextCycleRewards(ERC20 strategy) internal override returns (uint192) {
    if (msg.sender == address(replacedFlywheel)) {
      return 0;
    } else {
      // make it work for both pulled (claimed) and pushed (transferred some other way) rewards
      try ICERC20(address(strategy)).plugin() returns (address plugin) {
        try IPlugin(plugin).claimRewards() {} catch {}
      } catch {}

      uint256 rewardAmount = rewardToken.balanceOf(address(strategy));
      if (rewardAmount != 0) {
        rewardToken.safeTransferFrom(address(strategy), address(this), rewardAmount);
      }
      return uint192(rewardAmount);
    }
  }
}
