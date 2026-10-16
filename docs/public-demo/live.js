// app/src/risk.ts
function freezePrice(p) {
  if (p.lots === 0n || p.debt === 0n) return null;
  const cushion = p.equity - p.debt * p.freezeHealthBps / 10000n;
  const move = cushion * 10n ** (p.priceDecimals + p.lotDecimals) / (p.lots * 10n ** p.collateralDecimals);
  const price = p.isLong ? p.markPNS - move : p.markPNS + move;
  return price > 0n ? price : 0n;
}
function maxSweep(equity, debt, sweepHealthBps, freeBalance) {
  const floor = (debt * (sweepHealthBps + 5n) + 9999n) / 10000n;
  const room = equity > floor ? equity - floor : 0n;
  return room < freeBalance ? room : freeBalance;
}

// docs/public-demo/live.ts
var $ = (id) => document.getElementById(id);
var input = (id) => $(id).value;
function units(value, decimals) {
  if (!new RegExp(`^\\d{1,9}(?:\\.\\d{1,${decimals}})?$`).test(value)) throw new Error(`Enter a nonnegative value with at most ${decimals} decimal places.`);
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(fraction.padEnd(decimals, "0"));
}
function dollars(value, decimals) {
  const scale = 10n ** BigInt(decimals);
  return `$${value / scale}.${(value % scale).toString().padStart(decimals, "0")}`;
}
function clear(message) {
  $("status").textContent = message;
  $("freeze").textContent = "";
  $("sweep").textContent = "";
}
$("form").addEventListener("input", () => clear("Inputs changed. Calculate again."));
$("form").addEventListener("submit", (event) => {
  event.preventDefault();
  clear("Calculating...");
  try {
    const markPNS = units(input("mark"), 1), equity = units(input("equity"), 6), debt = units(input("debt"), 6), free = units(input("free"), 6);
    if (!/^\d{1,9}$/.test(input("lots"))) throw new Error("Lots must be a bounded nonnegative integer.");
    const lots = BigInt(input("lots"));
    const freeze = freezePrice({ markPNS, equity, debt, lots, isLong: input("side") === "long", freezeHealthBps: 11000n, priceDecimals: 1n, lotDecimals: 5n, collateralDecimals: 6n });
    const sweep = maxSweep(equity, debt, 12500n, free);
    $("status").textContent = "Computed with the shared risk engine";
    $("freeze").textContent = freeze === null ? "No freeze price: no position or no debt." : `Freeze price: ${dollars(freeze, 1)}`;
    $("sweep").textContent = `Maximum modeled sweep: ${dollars(sweep, 6)}`;
  } catch (error) {
    clear(error instanceof Error ? error.message : "Calculation failed.");
  }
});
