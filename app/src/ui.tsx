// Small shared UI pieces: number formatting, a stat with its source, and a button that runs an
// onchain action and shows progress and errors in plain words.
import { useCallback, useEffect, useState, type ReactNode } from "react";
import { BaseError, ContractFunctionRevertedError, formatUnits, parseUnits } from "viem";

export const usd = (v: bigint, digits = 2) =>
  `$${Number(formatUnits(v, 6)).toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits })}`;
export const pct = (bps: bigint | number) => `${(Number(bps) / 100).toLocaleString(undefined, { maximumFractionDigits: 2 })}%`;
export const parseUsd = (s: string) => {
  try {
    return parseUnits(s.trim() === "" ? "0" : s.trim(), 6);
  } catch {
    return 0n;
  }
};
export const short = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;

/** A figure with a hover/footnote naming exactly which contract call produced it. */
export function Stat({ label, value, source, tone }: { label: string; value: ReactNode; source: string; tone?: "good" | "bad" }) {
  return (
    <div className={`stat ${tone ?? ""}`}>
      <span className="stat-label">{label}</span>
      <strong className="stat-value">{value}</strong>
      <code className="stat-source" title="Where this number comes from">{source}</code>
    </div>
  );
}

/** Explains a contract revert in the app's words; the raw reason stays visible for the curious. */
function explain(e: unknown): string {
  let msg = (e as { shortMessage?: string; message?: string })?.shortMessage ?? (e as Error)?.message ?? String(e);
  // viem nests the decoded custom error a few causes deep; surface its name so it can be explained.
  if (e instanceof BaseError) {
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName ?? revert?.reason;
    if (name) msg = `${name}${revert?.data?.args?.length ? `(${revert.data.args.map(String).join(", ")})` : ""}`;
  }
  const known: [RegExp, string][] = [
    [/NoApproval/, "This wallet has no credit approval yet."],
    [/AboveLimit/, "That is more than your approved limit."],
    [/DepositTooSmall/, "Borrowing is limited to 3 times your own deposit."],
    [/LineTooLarge/, "One line can borrow at most 25% of the pool."],
    [/UtilizationCap/, "The pool is lent out to its cap right now."],
    [/LineAlreadyOpen/, "You already have an open line."],
    [/StaleMark/, "Perpl's BTC price is out of date, so trading is paused for safety. On the local fork, run app/scripts/fork-mark.sh."],
    [/NotTightening/, "That is looser than today's setting; propose it through the timelock instead."],
    [/Timelocked/, "This change is still inside its public waiting period."],
    [/HealthTooLow/, "That would leave the line too close to being frozen."],
    [/OpenPositions/, "Close your positions before closing the line."],
    [/LeverageTooHigh/, "That leverage is above this market's limit."],
    [/PasskeyRequired/, "Create and register a passkey first."],
    [/ApprovalExpired/, "Your credit approval has expired."],
    [/BelowVenueMinimum/, "Perpl needs at least 100 AUSD in a new account."],
    [/ExchangeCallFailed/, "Perpl rejected the order; the order book may be thin at that price."],
    [/PriceOutsideBand/, "The price moved outside the allowed band; try again."],
    [/ExposureTooLarge/, "That position would be bigger than this market allows for one line."],
    [/NewRiskBlocked/, "New risk is paused right now (circuit breaker)."],
    [/ExceededMaxWithdraw|InsufficientLiquidity/, "Not enough idle cash for an instant withdrawal; join the queue instead."],
    [/ExceededMaxDeposit|JuniorBelowMinimum/, "Senior can only grow while junior stays at least 20% of the pool."],
    [/NotAllowedError|AbortError|cancel/i, "The passkey request was cancelled."],
  ];
  for (const [re, text] of known) if (re.test(msg)) return `${text} (${msg.split("\n")[0].slice(0, 120)})`;
  return msg.split("\n")[0].slice(0, 200);
}

export function ActionButton({ label, run, onDone, disabled, kind }: {
  label: string; run: () => Promise<unknown>; onDone?: () => void; disabled?: boolean; kind?: "secondary";
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="action">
      <button
        type="button"
        className={kind ?? ""}
        disabled={disabled || busy}
        onClick={async () => {
          setBusy(true);
          setError(null);
          try {
            await run();
            onDone?.();
          } catch (e) {
            setError(explain(e));
          } finally {
            setBusy(false);
          }
        }}
      >
        {busy ? "Working..." : label}
      </button>
      {error && <span className="action-error" role="alert">{error}</span>}
    </span>
  );
}

/** Loads async data, with a reload function that pages call after every action. */
export function useLoad<T>(load: () => Promise<T>, deps: unknown[]): { data: T | null; error: string | null; reload: () => void } {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const fn = useCallback(load, deps);
  useEffect(() => {
    let live = true;
    fn().then((d) => live && (setData(d), setError(null)), (e) => live && setError(explain(e)));
    return () => {
      live = false;
    };
  }, [fn, tick]);
  return { data, error, reload: () => setTick((t) => t + 1) };
}
