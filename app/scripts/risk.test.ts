// Hand-calculated checks for app/src/risk.ts. Run: node --experimental-strip-types app/scripts/risk.test.ts
import assert from "node:assert/strict";
import { freezePrice, maxSweep } from "../src/risk.ts";

// Testnet BTC: price 1 decimal, lot 5 decimals, AUSD 6 decimals, so one lot at $100,000.0 is $1.
// A line with 1,000 deposit + 2,000 borrowed, long 6,000 lots, equity 2,994.5988, debt 2,000,
// freeze at 110%: cushion = 2,994.5988 - 2,200 = 794.5988 AUSD. Each $1 BTC move changes equity by
// 6,000 lots / 100,000 = $0.06, so BTC can fall 794.5988 / 0.06 = $13,243.31 before the freeze.
// In units: move (PNS) = 794.5988e6 * 10^(1+5) / (6,000 * 10^6) = 132,433.13 -> 132,433 PNS = $13,243.3
// freeze = 1,000,000 - 132,433 = 867,567 PNS = $86,756.7
assert.equal(
  freezePrice({
    markPNS: 1_000_000n, lots: 6_000n, isLong: true, equity: 2_994_598_800n, debt: 2_000_000_000n,
    freezeHealthBps: 11_000n, priceDecimals: 1n, lotDecimals: 5n, collateralDecimals: 6n,
  }),
  867_567n,
);

// Same book short: freeze when BTC rises by the same amount.
assert.equal(
  freezePrice({
    markPNS: 1_000_000n, lots: 6_000n, isLong: false, equity: 2_994_598_800n, debt: 2_000_000_000n,
    freezeHealthBps: 11_000n, priceDecimals: 1n, lotDecimals: 5n, collateralDecimals: 6n,
  }),
  1_132_433n,
);

// No position, no freeze price.
assert.equal(freezePrice({ markPNS: 1n, lots: 0n, isLong: true, equity: 1n, debt: 1n, freezeHealthBps: 1n,
  priceDecimals: 1n, lotDecimals: 5n, collateralDecimals: 6n }), null);

// Sweep: equity 1,500, debt 500, 125% floor plus a 0.05% margin -> floor 625.25, room 874.75;
// limited to the 600 free balance when that is smaller.
assert.equal(maxSweep(1_500_000_000n, 500_000_000n, 12_500n, 600_000_000n), 600_000_000n);
assert.equal(maxSweep(1_500_000_000n, 500_000_000n, 12_500n, 2_000_000_000n), 874_750_000n);
assert.equal(maxSweep(600_000_000n, 500_000_000n, 12_500n, 2_000_000_000n), 0n);

console.log("risk math: all hand calculations match");
