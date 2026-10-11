import { useState } from "react";
import { encodeFunctionData, type Address, type Hex } from "viem";
import { creditManagerAbi, riskCuratorAbi } from "../abi";
import { isLocalFork, publicClient, sendAs, type Deployment } from "../chain";
import { curatorProposals, linesOpened, readLine, readRules, stress } from "../protocol";
import { ActionButton, Stat, pct, short, usd, useLoad } from "../ui";

/** On the local fork the app acts as the curator and guardian through anvil impersonation. */
async function asRole(d: Deployment, role: "owner" | "guardian", functionName: string, args: unknown[]) {
  const who = (await publicClient.readContract({ address: d.curator, abi: riskCuratorAbi, functionName: role })) as Address;
  await sendAs(who, { address: d.curator, abi: riskCuratorAbi, functionName, args, chain: undefined } as never);
}

export function Curate({ d }: { d: Deployment }) {
  const rules = useLoad(() => readRules(d), []);
  const props = useLoad(() => curatorProposals(d), []);
  const [lineBps, setLineBps] = useState("20");
  const [loosenBps, setLoosenBps] = useState("30");
  const now = useLoad(async () => (await publicClient.getBlock()).timestamp, [props.data]);
  const reload = () => { rules.reload(); props.reload(); };
  const r = rules.data;
  return (
    <div className="stack">
      <section className="card">
        <p className="eyebrow">Curate</p>
        <h3>The rules that protect lenders</h3>
        <p className="muted">
          A curator runs this market. Making it safer takes effect at once. Making it riskier is posted publicly
          and waits out a timelock{r ? ` of ${Number(r.timelock) / 86_400} day${Number(r.timelock) === 86_400 ? "" : "s"}` : ""}, so lenders who disagree can leave first, and the guardian can veto it.
        </p>
        {isLocalFork() && <p className="note">Local fork: buttons here act as the curator and guardian by impersonation.</p>}
        {r && (
          <div className="stats">
            <Stat label="Most one line can borrow" value={`${pct(r.maxLineBps)} of the pool`} source="CreditManager.maxLineBps" />
            <Stat label="Borrow per $1 of deposit" value={`$${Number(r.maxLeverageOnDepositBps) / 10_000}`} source="CreditManager.maxLeverageOnDepositBps" />
            <Stat label="Frozen at health" value={pct(r.freezeHealthBps)} source="CreditManager.riskParams().freezeHealthBps" />
            <Stat label="No new risk below" value={pct(r.openHealthBps)} source="riskParams().openHealthBps" />
            <Stat label="BTC leverage cap" value={`${Number(r.maxLeverageHdths) / 100}x`} source="TradeGuard.markets(16)" />
            <Stat label="Price band" value={pct(r.bandBps)} source="TradeGuard.markets(16).bandBps" />
            <Stat label="BTC position cap per line" value={r.exposureCap ? usd(r.exposureCap, 0) : "None"} source="TradeGuard.exposureCap(16)" />
            <Stat label="Freeze bounty" value={`${pct(r.bountyBps)}, max ${usd(r.maxBounty, 0)}`} source="CreditManager.freezeBounty()" />
            <Stat label="Guardian" value={short(r.guardian)} source="RiskCurator.guardian()" />
          </div>
        )}
      </section>

      <section className="card">
        <h3>Make it safer now</h3>
        <div className="row">
          <label className="inline">Max per line (% of pool)<input inputMode="decimal" value={lineBps} onChange={(e) => setLineBps(e.target.value)} /></label>
          <ActionButton label="Tighten now" run={() => asRole(d, "owner", "tightenMaxLine", [Math.round(Number(lineBps) * 100)])} onDone={reload} />
        </div>
        <p className="note">The contract refuses this button if the new value is looser than today's.</p>
        <h3>Propose a riskier setting</h3>
        <div className="row">
          <label className="inline">Max per line (% of pool)<input inputMode="decimal" value={loosenBps} onChange={(e) => setLoosenBps(e.target.value)} /></label>
          <ActionButton
            label="Propose (timelocked)"
            kind="secondary"
            run={() => asRole(d, "owner", "submit", [d.manager, encodeFunctionData({ abi: creditManagerAbi, functionName: "setMaxLineBps", args: [Math.round(Number(loosenBps) * 100)] })])}
            onDone={reload}
          />
        </div>
        <h4>Proposals</h4>
        {!props.data?.proposals.length && <p className="note">Nothing pending.</p>}
        {props.data?.proposals.map((p) => {
          const ready = now.data !== null && now.data >= p.validAt;
          return (
            <div className="queue-item" key={p.id}>
              <span>
                {describe(d, p.target, p.data)}: <strong>{p.status}</strong>
                {p.status === "pending" && ` (can run from ${new Date(Number(p.validAt) * 1000).toLocaleString()})`}
              </span>
              {p.status === "pending" && (
                <span className="row">
                  <ActionButton label="Run" disabled={!ready} run={() => asRole(d, "owner", "execute", [p.target, p.data])} onDone={reload} />
                  <ActionButton label="Guardian veto" kind="secondary" run={() => asRole(d, "guardian", "revoke", [p.id])} onDone={reload} />
                </span>
              )}
            </div>
          );
        })}
      </section>
      <Stress d={d} />
    </div>
  );
}

function describe(d: Deployment, target: Address, data: Hex) {
  if (target.toLowerCase() === d.manager.toLowerCase() && data.startsWith("0x")) {
    try {
      const sel = data.slice(0, 10);
      const setMax = encodeFunctionData({ abi: creditManagerAbi, functionName: "setMaxLineBps", args: [0] }).slice(0, 10);
      if (sel === setMax) return `Raise max per line to ${pct(BigInt(`0x${data.slice(10)}`))}`;
    } catch { /* fall through */ }
  }
  return `Call ${data.slice(0, 10)} on ${short(target)}`;
}

function Stress({ d }: { d: Deployment }) {
  const [move, setMove] = useState(-30);
  const lines = useLoad(async () => {
    const opened = await linesOpened(d);
    const views = await Promise.all(opened.map((l) => readLine(d, l.line)));
    return views.filter((v) => v.state === 1 || v.state === 2).map((v) => v.address);
  }, []);
  const result = useLoad(async () => (lines.data ? stress(d, lines.data, BigInt(move * 100)) : null), [lines.data, move]);
  const x = result.data;
  return (
    <section className="card">
      <h3>Stress test</h3>
      <p className="muted">
        If BTC moved this much right now, what would each group lose? Every open line is revalued at the shocked
        price by the RiskLens contract, settled the way a frozen line is, and the shortfall runs through the loss order.
      </p>
      <label className="inline">BTC move: <strong>{move > 0 ? "+" : ""}{move}%</strong>
        <input type="range" min={-90} max={50} step={5} value={move} onChange={(e) => setMove(Number(e.target.value))} />
      </label>
      {x && (
        <div className="stats">
          <Stat label="Open lines tested" value={String(x.lines.length)} source="LineOpened events, state Active or Frozen" />
          <Stat label="Total loss" value={usd(x.totalLoss)} tone={x.totalLoss ? "bad" : "good"} source="RiskLens.stress().totalLoss" />
          <Stat label="Paid by reserve" value={usd(x.fromReserve)} source="RiskLens.stress().fromReserve" />
          <Stat label="Paid by junior" value={usd(x.fromJunior)} source="RiskLens.stress().fromJunior" />
          <Stat label="Paid by senior" value={usd(x.fromSenior)} tone={x.fromSenior ? "bad" : undefined} source="RiskLens.stress().fromSenior" />
        </div>
      )}
      {result.error && <p className="action-error">{result.error}</p>}
    </section>
  );
}
