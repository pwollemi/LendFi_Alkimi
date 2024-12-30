// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

contract WETHPriceConsumerV3 {
    int256 private price;
    uint256 private timestamp;

    constructor() {
        price = 2500e8;
        timestamp = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (
            1, // roundId
            price, // answer
            block.timestamp, // startedAt
            timestamp, // updatedAt
            1 // answeredInRound
        );
    }

    function setPrice(int256 _price) external {
        price = _price;
        timestamp = block.timestamp;
    }
}
