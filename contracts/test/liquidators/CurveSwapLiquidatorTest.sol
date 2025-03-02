// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { IERC20Upgradeable } from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import { ICurvePool } from "../../external/curve/ICurvePool.sol";
import { CurveSwapLiquidatorFunder } from "../../liquidators/CurveSwapLiquidatorFunder.sol";

import { CurveLpTokenPriceOracleNoRegistry } from "../../oracles/default/CurveLpTokenPriceOracleNoRegistry.sol";
import { CurveV2LpTokenPriceOracleNoRegistry } from "../../oracles/default/CurveV2LpTokenPriceOracleNoRegistry.sol";

import { BaseTest } from "../config/BaseTest.t.sol";

contract CurveSwapLiquidatorTest is BaseTest {
  CurveSwapLiquidatorFunder private csl;
  address private maiAddress = 0x3F56e0c36d275367b8C502090EDF38289b3dEa0d;
  address private val3EPSAddress = 0x5b5bD8913D766D005859CE002533D4838B0Ebbb5;

  address private lpTokenMai3EPS = 0x80D00D2c8d920a9253c3D65BA901250a55011b37;
  address private poolAddress = 0x68354c6E8Bbd020F9dE81EAf57ea5424ba9ef322;

  address xcDotStDotPool = 0x0fFc46cD9716a96d8D89E1965774A70Dcb851E50; // xcDOT-stDOT
  address xcDotAddress = 0xFfFFfFff1FcaCBd218EDc0EbA20Fc2308C778080; // 0
  address stDotAddress = 0xFA36Fe1dA08C89eC72Ea1F0143a35bFd5DAea108; // 1

  CurveLpTokenPriceOracleNoRegistry curveV1Oracle;
  CurveV2LpTokenPriceOracleNoRegistry curveV2Oracle;

  function afterForkSetUp() internal override {
    csl = new CurveSwapLiquidatorFunder();
    curveV1Oracle = CurveLpTokenPriceOracleNoRegistry(ap.getAddress("CurveLpTokenPriceOracleNoRegistry"));
    curveV2Oracle = CurveV2LpTokenPriceOracleNoRegistry(ap.getAddress("CurveV2LpTokenPriceOracleNoRegistry"));

    if (address(curveV1Oracle) == address(0)) {
      address[][] memory _poolUnderlyings = new address[][](1);
      _poolUnderlyings[0] = asArray(maiAddress, val3EPSAddress);
      //      _poolUnderlyings[1] = asArray(
      //        xcDotAddress,
      //        stDotAddress
      //      );
      curveV1Oracle = new CurveLpTokenPriceOracleNoRegistry();
      curveV1Oracle.initialize(asArray(lpTokenMai3EPS), asArray(poolAddress), _poolUnderlyings);
    }

    if (address(curveV2Oracle) == address(0)) {
      address lpTokenXcStDot = xcDotStDotPool;
      curveV2Oracle = new CurveV2LpTokenPriceOracleNoRegistry();
      curveV2Oracle.initialize(asArray(lpTokenXcStDot), asArray(xcDotStDotPool));
    }
  }

  function testRedeem() public fork(MOONBEAM_MAINNET) {
    IERC20Upgradeable xcDot = IERC20Upgradeable(xcDotAddress);

    ICurvePool curvePool = ICurvePool(xcDotStDotPool);

    assertEq(xcDotAddress, curvePool.coins(0), "coin 0 must be xcDOT");
    assertEq(stDotAddress, curvePool.coins(1), "coin 1 must be stDOT");

    uint256 xcForSt = curvePool.get_dy(0, 1, 1e10);
    emit log_uint(xcForSt);

    {
      // mock some calls
      vm.mockCall(
        xcDotAddress,
        abi.encodeWithSelector(xcDot.approve.selector, xcDotStDotPool, 10000000000),
        abi.encode(true)
      );
      vm.mockCall(
        xcDotAddress,
        abi.encodeWithSelector(xcDot.transferFrom.selector, address(csl), xcDotStDotPool, 10000000000),
        abi.encode(true)
      );
    }

    bytes memory data = abi.encode(curveV1Oracle, curveV2Oracle, xcDotAddress, stDotAddress, ap.getAddress("wtoken"));
    (IERC20Upgradeable shouldBeStDot, uint256 stDotOutput) = csl.redeem(xcDot, 1e10, data);
    assertEq(address(shouldBeStDot), stDotAddress, "output token does not match");

    assertApproxEqAbs(xcForSt, stDotOutput, uint256(10), "output amount does not match");
  }

  function testRedeemMAI() public fork(BSC_MAINNET) {
    ICurvePool curvePool = ICurvePool(poolAddress);

    assertEq(maiAddress, curvePool.coins(0), "coin 0 must be MAI");
    assertEq(val3EPSAddress, curvePool.coins(1), "coin 1 must be val3EPS");

    uint256 inputAmount = 1e10;

    uint256 maiForVal3EPS = curvePool.get_dy(0, 1, inputAmount);
    emit log_uint(maiForVal3EPS);

    dealMai(address(csl), inputAmount);

    bytes memory data = abi.encode(curveV1Oracle, address(0), maiAddress, val3EPSAddress, ap.getAddress("wtoken"));
    (IERC20Upgradeable shouldBeVal3EPS, uint256 outputAmount) = csl.redeem(
      IERC20Upgradeable(maiAddress),
      inputAmount,
      data
    );
    assertEq(address(shouldBeVal3EPS), val3EPSAddress, "output token does not match");

    assertEq(maiForVal3EPS, outputAmount, "output amount does not match");
  }

  function testEstimateInputAmount() public fork(BSC_MAINNET) {
    ICurvePool curvePool = ICurvePool(poolAddress);

    assertEq(maiAddress, curvePool.coins(0), "coin 0 must be MAI");
    assertEq(val3EPSAddress, curvePool.coins(1), "coin 1 must be val3EPS");

    bytes memory data = abi.encode(curveV1Oracle, address(0), maiAddress, val3EPSAddress, ap.getAddress("wtoken"));

    (IERC20Upgradeable inputToken, uint256 inputAmount) = csl.estimateInputAmount(2e10, data);

    emit log("input");
    emit log_uint(inputAmount);
    emit log_address(address(inputToken));
    uint256 shouldBeAround2e10 = curvePool.get_dy(1, 0, inputAmount);
    emit log("should be around 2e10");
    emit log_uint(shouldBeAround2e10);
    assertTrue(shouldBeAround2e10 >= 20e9 && shouldBeAround2e10 <= 21e9, "rough estimate didn't work");
  }

  function dealMai(address to, uint256 amount) internal {
    address whale = 0xc412eCccaa35621cFCbAdA4ce203e3Ef78c4114a; // anyswap
    vm.prank(whale);
    IERC20Upgradeable(maiAddress).transfer(to, amount);
  }
}
