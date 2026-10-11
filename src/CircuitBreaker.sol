// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title CircuitBreaker
/// @notice Decides whether new risk may be taken: opening lines, opening or growing positions, and
///         sweeping profit out. It can only make the protocol safer. Nothing here can block repaying,
///         freezing, unwinding or settling a line.
/// @dev Trips on any of:
///      - manual pause by the owner or a designated pauser (only the owner can unpause);
///      - Perpl pausing the market (perpetual status 0, per Perpl's SDK);
///      - AUSD trading below a floor on a Chainlink AUSD/USD feed, or that feed going stale
///        (the feed is optional, since Monad testnet has none);
///      - Perpl's insurance fund for the market falling below a share of open-interest notional,
///        which is when auto-deleveraging gets close.
contract CircuitBreaker is Ownable2Step {
    enum Reason {
        None,
        Paused,
        VenuePaused,
        Depeg,
        PegStale,
        InsuranceThin
    }

    uint8 internal constant PERP_PAUSED = 0;
    uint256 internal constant BPS = 10_000;

    address public pauser;
    bool public paused;

    IAggregatorV3 public pegFeed; // AUSD / USD; zero disables the peg check
    uint256 public minPegE8; // floor, 8 decimals, e.g. 99_500_000 = 0.995
    uint256 public maxPegAgeSec;

    /// @notice Minimum insurance fund as basis points of one side's open-interest notional. Zero
    ///         disables the check.
    uint16 public minInsuranceBps;

    error NotPauser();
    error InvalidConfig();

    event PauserSet(address indexed pauser);
    event PausedSet(bool paused, address indexed by);
    event PegConfigSet(address feed, uint256 minPegE8, uint256 maxPegAgeSec);
    event InsuranceFloorSet(uint16 minInsuranceBps);

    constructor(address owner_) Ownable(owner_) {}

    function setPauser(address pauser_) external onlyOwner {
        pauser = pauser_;
        emit PauserSet(pauser_);
    }

    /// @notice Stop new risk. The owner or the pauser can pause; only the owner can resume.
    function pause() external {
        if (msg.sender != pauser && msg.sender != owner()) revert NotPauser();
        paused = true;
        emit PausedSet(true, msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PausedSet(false, msg.sender);
    }

    function setPegConfig(IAggregatorV3 feed, uint256 minPegE8_, uint256 maxPegAgeSec_) external onlyOwner {
        if (address(feed) != address(0) && (minPegE8_ == 0 || minPegE8_ > 1e8 || maxPegAgeSec_ == 0)) {
            revert InvalidConfig();
        }
        pegFeed = feed;
        minPegE8 = minPegE8_;
        maxPegAgeSec = maxPegAgeSec_;
        emit PegConfigSet(address(feed), minPegE8_, maxPegAgeSec_);
    }

    function setMinInsuranceBps(uint16 bps) external onlyOwner {
        if (bps > BPS) revert InvalidConfig();
        minInsuranceBps = bps;
        emit InsuranceFloorSet(bps);
    }

    /// @notice Whether new risk is allowed anywhere (opening lines, sweeping profit).
    function globalStatus() public view returns (Reason) {
        if (paused) return Reason.Paused;
        return _pegStatus();
    }

    /// @notice Whether new risk is allowed in one Perpl market.
    function marketStatus(IExchange exchange, uint256 perpId) external view returns (Reason) {
        Reason r = globalStatus();
        if (r != Reason.None) return r;
        IExchange.PerpetualInfoV2 memory p = exchange.getPerpetualInfoV2(perpId);
        if (IExchange.PerpStatusEnum.unwrap(p.status) == PERP_PAUSED) return Reason.VenuePaused;
        if (minInsuranceBps != 0) {
            uint256 oi = p.longOpenInterestLNS > p.shortOpenInterestLNS ? p.longOpenInterestLNS : p.shortOpenInterestLNS;
            (,,, uint256 collateralDecimals,,) = exchange.getExchangeInfo();
            uint256 notional = (p.markPNS * oi * 10 ** collateralDecimals) / 10 ** (p.priceDecimals + p.lotDecimals);
            if (p.insuranceBalanceCNS * BPS < notional * minInsuranceBps) return Reason.InsuranceThin;
        }
        return Reason.None;
    }

    function _pegStatus() internal view returns (Reason) {
        IAggregatorV3 feed = pegFeed;
        if (address(feed) == address(0)) return Reason.None;
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (updatedAt == 0 || block.timestamp > updatedAt + maxPegAgeSec) return Reason.PegStale;
            if (answer <= 0) return Reason.Depeg;
            uint8 d = feed.decimals();
            uint256 priceE8 = d >= 8 ? uint256(answer) / 10 ** (d - 8) : uint256(answer) * 10 ** (8 - d);
            if (priceE8 < minPegE8) return Reason.Depeg;
            return Reason.None;
        } catch {
            return Reason.PegStale; // an unreadable feed counts as stale: fail safe
        }
    }
}
