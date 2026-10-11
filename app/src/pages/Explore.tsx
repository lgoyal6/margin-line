import type { Deployment } from "../chain";
import { lineEvents, lineStates, linesOpened, readLine, readMarket } from "../protocol";
import { Stat, pct, short, usd, useLoad } from "../ui";

export function Explore({ d }: { d: Deployment }) {
  const market = useLoad(() => readMarket(d), []);
  const lines = useLoad(async () => {
    const opened = await linesOpened(d);
    return Promise.all(
      opened.map(async (o) => {
        const [view, events] = await Promise.all([readLine(d, o.line), lineEvents(d, o.line)]);
        const bounty = events.filter((e) => e.name === "BountyPaid").reduce((s, e) => s + (e.args.amount as bigint), 0n);
        return { ...o, view, frozen: events.some((e) => e.name === "Frozen"), bounty, swept: events.filter((e) => e.name === "Swept").length };
      }),
    );
  }, []);
  const m = market.data;
  const all = lines.data ?? [];
  const frozen = all.filter((l) => l.frozen).length;
  const bounties = all.reduce((s, l) => s + l.bounty, 0n);
  return (
    <div className="stack">
      <section className="card">
        <p className="eyebrow">Explore</p>
        <h3>Everything, checkable</h3>
        <p className="muted">
          Every number on this page is read straight from the contracts or their event logs; the small code under each
          one names the exact call. Lines are found from <code>LineOpened</code> events, scanned in 100-block windows
          (the public RPC refuses wider ranges).
        </p>
        <div className="stats">
          <Stat label="Lines ever opened" value={String(all.length)} source="CreditManager LineOpened events" />
          <Stat label="Open now" value={String(all.filter((l) => l.view.state === 1).length)} source="CreditLine.state() == Active" />
          <Stat label="Ever frozen" value={String(frozen)} source="CreditLine Frozen events" />
          <Stat label="Bounties paid to freezers" value={usd(bounties)} source="CreditLine BountyPaid events" />
          {m && <Stat label="Lent out" value={usd(m.outstanding, 0)} source="CreditPool.principalOutstanding" />}
          {m && <Stat label="Pool losses" value={usd(m.losses)} source="CreditPool.totalLosses" />}
        </div>
      </section>
      <section className="card">
        <h3>Lines</h3>
        {lines.error && <p className="action-error">{lines.error}</p>}
        {!lines.data && !lines.error && <p className="muted">Scanning events...</p>}
        {lines.data && !all.length && <p className="note">No lines yet.</p>}
        {all.length > 0 && (
          <table>
            <thead><tr><th>Line</th><th>Borrower</th><th>State</th><th>Borrowed</th><th>Owes</th><th>Health</th><th>Bounty</th></tr></thead>
            <tbody>
              {all.map((l) => (
                <tr key={l.line}>
                  <td className="mono" title={l.line}>{short(l.line)}</td>
                  <td className="mono" title={l.borrower}>{short(l.borrower)}</td>
                  <td>{lineStates[l.view.state]}{l.frozen ? " (was frozen)" : ""}</td>
                  <td>{usd(l.principal, 0)}</td>
                  <td>{usd(l.view.debt)}</td>
                  <td>{l.view.debt ? pct(l.view.health) : "-"}</td>
                  <td>{l.bounty ? usd(l.bounty) : "-"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p className="note">Columns come from: LineOpened (line, borrower, borrowed), CreditLine.state(), debt(), healthBps(), and BountyPaid events.</p>
      </section>
    </div>
  );
}
