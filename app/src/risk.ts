// Pure risk math shared by the trade ticket and its test (app/scripts/risk.test.ts).

/**
 * The BTC mark price at which a line with one BTC position would be frozen.
 *
 * Equity moves by `lots * scale` per unit of price, where scale converts Perpl price and lot units
 * into AUSD units: 10^collateralDecimals / 10^(priceDecimals + lotDecimals). A line is frozen when
 * equity * 10,000 / debt falls below `freezeHealthBps`, so:
 *   long:  freeze = mark - (equity - debt * freezeBps / 10,000) / (lots * scale)
 *   short: freeze = mark + (equity - debt * freezeBps / 10,000) / (lots * scale)
 * Returns null with no position or no debt. All amounts are integers in Perpl/AUSD units.
 */
export function freezePrice(p: {
  markPNS: bigint;
  lots: bigint;
  isLong: boolean;
  equity: bigint;
  debt: bigint;
  freezeHealthBps: bigint;
  priceDecimals: bigint;
  lotDecimals: bigint;
  collateralDecimals: bigint;
}): bigint | null {
  if (p.lots === 0n || p.debt === 0n) return null;
  const cushion = p.equity - (p.debt * p.freezeHealthBps) / 10_000n; // AUSD units above the freeze line
  // price move (PNS) = cushion / (lots * 10^cd / 10^(pd+ld)) = cushion * 10^(pd+ld) / (lots * 10^cd)
  const move = (cushion * 10n ** (p.priceDecimals + p.lotDecimals)) / (p.lots * 10n ** p.collateralDecimals);
  const price = p.isLong ? p.markPNS - move : p.markPNS + move;
  return price > 0n ? price : 0n;
}

/** Largest sweep that keeps health at or above `sweepHealthBps`, limited by the free Perpl balance.
 *  Interest accrues every second between this read and the transaction, so the floor carries a
 *  5 basis-point safety margin; without it a "max" sweep lands a hair under the threshold. */
export function maxSweep(equity: bigint, debt: bigint, sweepHealthBps: bigint, freeBalance: bigint): bigint {
  const floor = (debt * (sweepHealthBps + 5n) + 9_999n) / 10_000n;
  const room = equity > floor ? equity - floor : 0n;
  return room < freeBalance ? room : freeBalance;
}
