// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.0;

interface IUniswapV1Factory {
    function getExchange(address token) external view returns (address);
}
