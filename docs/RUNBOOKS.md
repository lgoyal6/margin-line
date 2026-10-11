# Margin Line runbooks

Addresses come from the active deployment record (`deployments/*.json`). Confirm the network and RPC
before signing. When unsure, pause first: pausing only blocks new risk, never closing, repaying,
freezing, unwinding or settling.

In a factory market every component is owned by its `RiskCurator`. Two kinds of action exist:

- **Instant**: `RiskCurator.pause()` (curator owner or guardian; the guardian is also the breaker's
  pauser), `RiskCurator.revokeUnderwriter()`, and any `RiskCurator.tighten*` call.
- **Timelocked**: everything else, including unpausing. The curator owner calls
  `RiskCurator.submit(target, calldata)`; after `RiskCurator.timelock()` seconds anyone calls
  `RiskCurator.execute(target, calldata)`; the guardian can cancel with `RiskCurator.revoke(id)`.

Each runbook names the monitor alert (`monitor/src/monitor.ts`) that should send you to it.

## Pause all new risk (alert: `breaker`, or any situation you do not understand)

1. Guardian or curator owner calls `RiskCurator.pause()`.
2. Confirm `CircuitBreaker.globalStatus()` returns 1 (Paused) and that `CreditManager.openLine` and
   risk-increasing `CreditLine.trade` calls revert with `NewRiskBlocked`.
3. When the cause is fixed, the curator owner calls
   `RiskCurator.submit(breaker, abi.encodeCall(CircuitBreaker.unpause, ()))`, waits out the timelock,
   then anyone calls `RiskCurator.execute` with the same arguments.

## AUSD depeg (alert: `breaker` with reason Depeg or PegStale)

1. Read `CircuitBreaker.globalStatus()` and the feed's `latestRoundData()`.
2. The breaker already blocks new risk on a depeg or stale feed. If the feed itself is wrong, call
   `RiskCurator.pause()` so new risk stays blocked whatever the feed says.
3. Change the feed or its thresholds only through the timelock:
   `RiskCurator.submit(breaker, abi.encodeCall(CircuitBreaker.setPegConfig, (feed, minPegE8, maxPegAgeSec)))`.
4. Confirm close, repay, freeze, unwind and settle still work.

## Perpl market paused or its price stale (alert: `breaker` with reason VenuePaused; trades failing with `StaleMark`)

1. Read `CircuitBreaker.marketStatus(exchange, perpId)` and Perpl's
   `getPerpetualInfoV2(perpId)` (`status`, `markPNS`, `markTimestamp`).
2. Opening risk and taking profit already refuse a mark older than `TradeGuard.maxMarkAgeSec()`. To
   stop the market entirely, the curator owner calls `RiskCurator.tightenMarket(perpId, false, 0, 0)`
   (disallowing is instant; existing positions can still be unwound at the band).
3. Re-allow it only through the timelock: `RiskCurator.submit(guard, abi.encodeCall(TradeGuard.setMarket, (perpId, true, maxLeverageHdths, bandBps)))`.

## Keeper down (alert: `missed-freeze:<line>`)

1. For each line named in the alert, anyone with gas money calls, with fixed gas ceilings
   (Monad bills the limit, and estimates for calls into Perpl run tight):
   - `CreditLine.freeze()`, gas 1,500,000 (earns the freeze bounty),
   - `CreditLine.unwind(perpId, type(uint256).max)` for each market with a position, gas 1,500,000,
   - `CreditLine.settleFrozen()`, gas 1,500,000.
2. Check `CreditLine.state()` is 3 (Closed) and the pool's `principalOf(line)` is 0.
3. Restart the keeper (`keeper/`), refill its wallet, and confirm it freezes the next unhealthy line.

## Underwriter key compromised

1. Guardian or curator owner calls `RiskCurator.pause()`: `openLine` checks the breaker, so no
   approval can be used while paused.
2. Curator owner calls `RiskCurator.revokeUnderwriter()` so no new approvals can be issued.
3. Approvals already issued cannot be revoked; they stay usable until their `expiry`. List them from
   `CreditManager.Approved` events and keep the market paused until the latest one expires.
4. Install the new underwriter through the timelock:
   `RiskCurator.submit(manager, abi.encodeCall(CreditManager.setUnderwriter, (newUnderwriter)))`.

## Withdrawal queue stuck (alert: `queue-stuck:<tranche>`)

1. Read `TrancheVault.queueLength()`, `head()`, `instantLiquidity()` and
   `CreditPool.withdrawable(tranche)`.
2. If there is cash, anyone calls `TrancheVault.processQueue(maxRequests)`; requests are paid strictly
   in order.
3. If there is no cash, liquidity returns only as lines repay or close. Consider tightening
   `RiskCurator.tightenMaxLine` and `RiskCurator.tightenPool` (lower `maxUtilizationBps`) so new
   lending stops competing with the queue.
4. A lender can always leave the queue with `TrancheVault.cancelRequest(id)`.

## Pool shape warnings (alerts: `utilization`, `reserve-thin`, `junior-thin`, `line-at-risk:<line>`)

- `utilization` warn above 85%, critical at the cap: lenders can only leave through the queue. Tighten
  `maxUtilizationBps` with `RiskCurator.tightenPool` to stop new lines.
- `reserve-thin`: expected for a young market, since the reserve fills from interest. Raise the reserve
  share with `RiskCurator.tightenPool` if losses are expected.
- `junior-thin` (junior under 22%): senior deposits stop at 20% automatically; ask junior lenders to
  add capital or raise `minJuniorBps` with `RiskCurator.tightenPool`.
- `line-at-risk`: informational. The trader cannot add risk; watch for `missed-freeze` if it falls further.
