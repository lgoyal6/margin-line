// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ScoreRules} from "../../src/ScoreRules.sol";

contract ScoreRulesTest is Test {
    using stdJson for string;

    function test_pythonVectorsMatchSolidity() public {
        string memory json = vm.readFile("test/fixtures/score_vectors.json");
        uint256[] memory active = json.readUintArray(".activeDays");
        uint256 n = active.length;
        uint256[] memory closes = json.readUintArray(".closes");
        int256[] memory pnl = json.readIntArray(".pnlExtMicro");
        uint256[] memory lev = json.readUintArray(".avgLevBps");
        uint256[] memory liq = json.readUintArray(".liqHist");
        uint256[] memory washShare = json.readUintArray(".washShareBps");
        bool[] memory wash = json.readBoolArray(".washPair");
        uint256[] memory deposits = json.readUintArray(".maxDepositMicro");
        bool[] memory expectedEligible = json.readBoolArray(".eligible");
        uint256[] memory expectedLimit = json.readUintArray(".limitMicro");
        assertGe(n, 1000);
        for (uint256 i; i < n; ++i) {
            ScoreRules.Features memory f = ScoreRules.Features({
                activeDays: uint32(active[i]), closes: uint32(closes[i]), pnlExtMicro: pnl[i],
                avgLevBps: uint32(lev[i]), liqHist: uint32(liq[i]), washShareBps: uint32(washShare[i]),
                washPair: wash[i], maxDepositMicro: deposits[i]
            });
            assertEq(ScoreRules.eligible(f), expectedEligible[i], "eligibility mismatch");
            assertEq(ScoreRules.limitFor(f), expectedLimit[i], "limit mismatch");
            assertEq(ScoreRules.aprFor(f), expectedEligible[i] ? 800 : 0, "apr mismatch");
        }
    }
}
