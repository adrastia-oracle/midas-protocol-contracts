pragma solidity >=0.8.0;

interface IRouter {
  function isPair(address pair) external view returns (bool);

  function getReserves(
    address tokenA,
    address tokenB,
    bool stable
  ) external view returns (uint256 reserveA, uint256 reserveB);

  function pairFor(
    address tokenA,
    address tokenB,
    bool stable
  ) external view returns (address pair);

  function removeLiquidity(
    address tokenA,
    address tokenB,
    bool stable,
    uint256 liquidity,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
  ) external returns (uint256 amountA, uint256 amountB);

  function addLiquidity(
    address tokenA,
    address tokenB,
    bool stable,
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

  function swapExactTokensForTokensSimple(
    uint256 amountIn,
    uint256 amountOutMin,
    address tokenFrom,
    address tokenTo,
    bool stable,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory amounts);
}
