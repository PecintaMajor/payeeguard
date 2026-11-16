// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Minimal ERC-20 interface used by PayeeGuard (transferFrom-based payments).
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}
