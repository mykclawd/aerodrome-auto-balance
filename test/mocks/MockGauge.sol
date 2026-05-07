// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract MockGauge {
    mapping(address => mapping(uint256 => bool)) public staked;

    function setStaked(address account, uint256 tokenId, bool isStaked) external {
        staked[account][tokenId] = isStaked;
    }

    function deposit(uint256 tokenId) external {
        staked[msg.sender][tokenId] = true;
    }

    function withdraw(uint256 tokenId) external {
        staked[msg.sender][tokenId] = false;
    }

    function getReward(address) external {}

    function stakedContains(address account, uint256 tokenId) external view returns (bool) {
        return staked[account][tokenId];
    }
}
