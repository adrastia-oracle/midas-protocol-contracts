// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

struct Observation {
  uint256 timestamp;
  uint256 reserve0Cumulative;
  uint256 reserve1Cumulative;
}

interface IPair {
  function observations(uint256 index) external pure returns (Observation memory);

  function name() external pure returns (string memory);

  function symbol() external pure returns (string memory);

  function decimals() external pure returns (uint8);

  function totalSupply() external view returns (uint256);

  function factory() external view returns (address);

  function token0() external view returns (address);

  function token1() external view returns (address);

  function metadata()
    external
    view
    returns (
      uint256 dec0,
      uint256 dec1,
      uint256 r0,
      uint256 r1,
      bool st,
      address t0,
      address t1
    );

  function claimFees() external returns (uint256, uint256);

  function tokens() external returns (address, address);

  function stable() external view returns (bool);

  function observationLength() external view returns (uint256);

  function lastObservation() external view returns (Observation memory);

  function current(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);

  function currentCumulativePrices()
    external
    view
    returns (
      uint256 reserve0Cumulative,
      uint256 reserve1Cumulative,
      uint256 blockTimestamp
    );

  function transferFrom(
    address src,
    address dst,
    uint256 amount
  ) external returns (bool);

  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external;

  function swap(
    uint256 amount0Out,
    uint256 amount1Out,
    address to,
    bytes calldata data
  ) external;

  function burn(address to) external returns (uint256 amount0, uint256 amount1);

  function mint(address to) external returns (uint256 liquidity);

  function sync() external;

  function transfer(address dst, uint256 amount) external returns (bool);

  function getReserves()
    external
    view
    returns (
      uint256 _reserve0,
      uint256 _reserve1,
      uint256 _blockTimestampLast
    );

  function getAmountOut(uint256, address) external view returns (uint256);
}
