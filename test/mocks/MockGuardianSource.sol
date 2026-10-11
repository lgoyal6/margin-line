// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Stands in for RiskCurator as the ScoreOracle's guardian source in unit tests.
contract MockGuardianSource {
    address public guardian;

    constructor(address guardian_) {
        guardian = guardian_;
    }

    function setGuardian(address guardian_) external {
        guardian = guardian_;
    }
}

/// @notice A contract wallet that accepts native payouts with more than 2,300 gas of work, like a
///         multisig. `transfer` to it would fail.
contract GasHungryReceiver {
    uint256 public received;

    receive() external payable {
        for (uint256 i; i < 10; ++i) received += msg.value;
    }

    function call(address target, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        require(ok, "call failed");
        return ret;
    }
}
