// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal interface for an Aerodrome SlipStream CLGauge.
interface ICLGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(address account) external;
    function stakedContains(address account, uint256 tokenId) external view returns (bool);
}
