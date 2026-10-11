// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The integer form of the fixed Python approval rule.
library ScoreRules {
    uint256 internal constant MAX_LIMIT_MICRO = 10_000e6;
    uint256 internal constant APR_BPS = 800;

    struct Features {
        uint32 activeDays;
        uint32 closes;
        int256 pnlExtMicro;
        uint32 avgLevBps;
        uint32 liqHist;
        uint32 washShareBps;
        bool washPair;
        uint256 maxDepositMicro;
    }

    function eligible(Features memory f) internal pure returns (bool) {
        return f.activeDays >= 3 && f.closes >= 10 && f.liqHist == 0 && f.pnlExtMicro > 0
            && f.avgLevBps <= 50_000 && !f.washPair;
    }

    function limitFor(Features memory f) internal pure returns (uint256) {
        if (!eligible(f)) return 0;
        uint256 doubled = f.maxDepositMicro * 2;
        return doubled < MAX_LIMIT_MICRO ? doubled : MAX_LIMIT_MICRO;
    }

    function aprFor(Features memory f) internal pure returns (uint256) {
        return eligible(f) ? APR_BPS : 0;
    }
}
