// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// Mock Oracle for testing specific scenarios with historical data support
contract MockPriceOracle {
    // Current price data
    int256 private _price;
    uint80 private _roundId;
    uint256 private _timestamp;
    uint80 private _answeredInRound;

    // Historical round data storage
    struct RoundData {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
        bool exists;
    }

    // Map roundId to its data
    mapping(uint80 => RoundData) private _roundData;

    constructor() {
        _price = 1000 * 10 ** 8;
        _roundId = 1;
        _timestamp = block.timestamp;
        _answeredInRound = 1;

        // Initialize first round data
        _roundData[1] =
            RoundData({answer: _price, startedAt: 0, updatedAt: _timestamp, answeredInRound: 1, exists: true});
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, 0, _timestamp, _answeredInRound);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(_roundData[roundId].exists, "No data available for this round");

        RoundData memory data = _roundData[roundId];
        return (roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound);
    }

    function setPrice(int256 price) external {
        _price = price;
        // Update current round data
        _roundData[_roundId].answer = price;
    }

    function setRoundId(uint80 roundId) external {
        // Store current round data before updating
        _storeCurrentRoundData();

        _roundId = roundId;

        // Initialize new round data if it doesn't exist
        if (!_roundData[roundId].exists) {
            _roundData[roundId] =
                RoundData({answer: _price, startedAt: 0, updatedAt: _timestamp, answeredInRound: roundId, exists: true});
        }
    }

    function setTimestamp(uint256 timestamp) external {
        _timestamp = timestamp;
        _roundData[_roundId].updatedAt = timestamp;
    }

    function setAnsweredInRound(uint80 answeredInRound) external {
        _answeredInRound = answeredInRound;
        _roundData[_roundId].answeredInRound = answeredInRound;
    }

    // Set historical round data for testing price volatility
    function setHistoricalRoundData(uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound)
        external
    {
        _roundData[roundId] = RoundData({
            answer: answer,
            startedAt: 0,
            updatedAt: updatedAt,
            answeredInRound: answeredInRound,
            exists: true
        });
    }

    // Store current price data in round storage
    function _storeCurrentRoundData() private {
        _roundData[_roundId] = RoundData({
            answer: _price,
            startedAt: 0,
            updatedAt: _timestamp,
            answeredInRound: _answeredInRound,
            exists: true
        });
    }
}
