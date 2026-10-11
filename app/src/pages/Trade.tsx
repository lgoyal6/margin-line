import { useState } from "react";
import { creditLineAbi } from "../abi";
import { isLocalFork, walletFor, wait, type Deployment } from "../chain";
import { actions, clearSession, createAccount, isRegistered, loadSession, prove, registerOnchain, type Session } from "../passkey";
import {
  activeLine, approvalOf, balances, forkDemoApproval, forkFund, lineRisk, lineStates, openLine, readBtc, readLine, readRules,
  topUp, trade,
} from "../protocol";
import { explain, loadEpoch, oracleStatus, verifyOnchain, type ScoreLeaf } from "../score";
import { ActionButton, Stat, parseUsd, pct, short, usd, useLoad } from "../ui";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { publicClient } from "../chain";
import type { Address, Hex } from "viem";

export function Trade({ d }: { d: Deployment }) {
  const [session, setSession] = useState<Session | null>(loadSession());
  return (
    <div className="stack">
      <Account d={d} session={session} setSession={setSession} />
      <ScoreCheck d={d} />
      {session && <Credit d={d} session={session} />}
    </div>
  );
}

// ------------------------------------------------------------ 1. account

function Account({ d, session, setSession }: { d: Deployment; session: Session | null; setSession: (s: Session | null) => void }) {
  const state = useLoad(async () => {
    if (!session) return null;
    const [b, registered] = await Promise.all([balances(d, session.address), isRegistered(d.identity, session.address)]);
    return { ...b, registered };
  }, [session?.address]);
  return (
    <section className="card">
      <p className="eyebrow">Step 1</p>
      <h3>Your account is a passkey</h3>
      <p className="muted">
        No seed phrase and no browser extension. Your device's passkey (Face ID, Touch ID or a security key) creates
        your wallet, and the same passkey must approve every withdrawal.
      </p>
      {!session ? (
        <ActionButton label="Create account with a passkey" run={async () => setSession(await createAccount())} />
      ) : (
        <>
          <div className="stats">
            <Stat label="Wallet" value={short(session.address)} source="derived from your passkey (Mera, PRF)" />
            <Stat label="Gas money" value={state.data ? `${(Number(state.data.mon) / 1e18).toFixed(2)} MON` : "..."} source="eth_getBalance" />
            <Stat label="AUSD (dollars)" value={state.data ? usd(state.data.ausd) : "..."} source="AUSD.balanceOf(wallet)" />
            <Stat label="Passkey onchain" value={state.data?.registered ? "Registered" : "Not yet"} tone={state.data?.registered ? "good" : undefined} source="IdentityRegistry.hasPasskey" />
          </div>
          <div className="row">
            {isLocalFork() && (
              <ActionButton label="Get test funds (local fork)" kind="secondary" run={() => forkFund(d, session.address, 5_000_000_000n)} onDone={state.reload} />
            )}
            {state.data && !state.data.registered && (
              <ActionButton label="Register passkey onchain" disabled={!state.data.mon} run={() => registerOnchain(d.identity, session)} onDone={state.reload} />
            )}
            <button type="button" className="link" onClick={() => { clearSession(); setSession(null); }}>Sign out</button>
          </div>
          {isLocalFork() && <p className="note">Test funds come from the local fork only: 10 MON for gas and $5,000 of AUSD.</p>}
        </>
      )}
    </section>
  );
}

// ------------------------------------------------------------ 2. score

function ScoreCheck({ d }: { d: Deployment }) {
  const epoch = useLoad(async () => {
    const e = await loadEpoch();
    return e ? { e, status: await oracleStatus(d, e) } : null;
  }, [d.scoreOracle]);
  const [query, setQuery] = useState("");
  const [result, setResult] = useState<{ leaf: ScoreLeaf; onchain: boolean } | "missing" | null>(null);
  const e = epoch.data?.e;
  return (
    <section className="card">
      <p className="eyebrow">Step 2</p>
      <h3>How much credit would a trader get?</h3>
      <p className="muted">
        Limits come from real Perpl trading history. Every scored account is one entry in a published list whose
        fingerprint (a Merkle root) is posted onchain; anyone can challenge a wrong entry for a day before it counts.
      </p>
      {!e ? (
        <p className="note">{epoch.error ?? "No score list has been published to this market yet."}</p>
      ) : (
        <>
          <div className="stats">
            <Stat label="Score list" value={`#${e.epoch}`} source={`ScoreOracle ${short(d.scoreOracle)}`} />
            <Stat label="Accounts scored" value={e.leaves.length.toLocaleString()} source="published epoch file" />
            <Stat label="Approved" value={e.eligible.toLocaleString()} source="leaves with a limit" />
            <Stat
              label="Onchain"
              value={epoch.data!.status.matches ? (epoch.data!.status.finalized ? "Final, matches" : "In challenge window") : "Does not match"}
              tone={epoch.data!.status.matches && epoch.data!.status.finalized ? "good" : "bad"}
              source="ScoreOracle.rootFor / isFinalized"
            />
          </div>
          <div className="row">
            <input aria-label="Perpl account number" placeholder="Perpl account number" value={query} onChange={(ev) => setQuery(ev.target.value)} />
            <ActionButton
              label="Check"
              run={async () => {
                const leaf = e.leaves.find((l) => String(l.perplAccount) === query.trim());
                setResult(leaf ? { leaf, onchain: await verifyOnchain(d, e, leaf) } : "missing");
              }}
            />
            <button type="button" className="link" onClick={() => setQuery(String(e.leaves.find((l) => l.limit > 0)?.perplAccount ?? ""))}>
              Try an approved trader
            </button>
          </div>
          {result === "missing" && <p className="note">That account has no trades before block {e.cutoffBlock.toLocaleString()}.</p>}
          {result && result !== "missing" && (
            <div className="verdict-box">
              <p className={result.leaf.limit > 0 ? "verdict good" : "verdict bad"}>
                {result.leaf.limit > 0 ? `Approved for up to ${usd(BigInt(result.leaf.limit), 0)} at ${pct(result.leaf.aprBps)} a year` : "Not approved"}
              </p>
              <ul className="rules">
                {explain(result.leaf.features).map((r) => (
                  <li key={r.rule} className={r.ok ? "ok" : "no"}>{r.ok ? "Pass" : "Fail"}: {r.rule} <span>({r.value})</span></li>
                ))}
              </ul>
              <p className="note">
                {result.onchain
                  ? "Verified onchain: the oracle contract confirmed this exact entry is in the posted list."
                  : "Not verified: this entry is not in the list posted onchain."}
              </p>
            </div>
          )}
          <p className="note">
            Scores come from Perpl on Monad mainnet; this app lends on testnet. A mainnet account cannot be linked to a
            testnet wallet, so the next step uses a labeled demo approval instead of a score.
          </p>
        </>
      )}
    </section>
  );
}

// ------------------------------------------------------------ 3. credit line

function Credit({ d, session }: { d: Deployment; session: Session }) {
  const s = useLoad(async () => {
    const [rules, btc, line, approval] = await Promise.all([readRules(d), readBtc(d), activeLine(d, session.address), approvalOf(d, session.address)]);
    const view = line ? await readLine(d, line) : null;
    return { rules, btc, approval, view, risk: view ? lineRisk(view, btc, rules) : null };
  }, [session.address]);
  if (s.error) return <section className="card"><p className="action-error">{s.error}</p></section>;
  if (!s.data) return <section className="card"><p className="muted">Loading your line...</p></section>;
  const { rules, btc, approval, view, risk } = s.data;
  return view ? <LineDashboard d={d} session={session} rules={rules} btc={btc} view={view} risk={risk!} reload={s.reload} />
    : <OpenForm d={d} session={session} approval={approval} rules={rules} reload={s.reload} />;
}

function OpenForm({ d, session, approval, rules, reload }: {
  d: Deployment; session: Session; approval: Awaited<ReturnType<typeof approvalOf>>; rules: Awaited<ReturnType<typeof readRules>>; reload: () => void;
}) {
  const [deposit, setDeposit] = useState("500");
  const [borrow, setBorrow] = useState("1000");
  const dep = parseUsd(deposit);
  const bor = parseUsd(borrow);
  const maxByDeposit = (dep * rules.maxLeverageOnDepositBps) / 10_000n;
  const problem = !approval.limit ? "No credit approval yet."
    : bor > approval.limit ? `More than your limit of ${usd(approval.limit, 0)}.`
    : bor > maxByDeposit ? `With a ${usd(dep, 0)} deposit you can borrow up to ${usd(maxByDeposit, 0)}.`
    : dep + bor < 100_000_000n ? "Perpl needs at least $100 in a new account." : null;
  return (
    <section className="card">
      <p className="eyebrow">Step 3</p>
      <h3>Open a credit line</h3>
      <p className="muted">
        You put in your own money first; it takes any loss before lenders do. You can borrow up to {Number(rules.maxLeverageOnDepositBps) / 10_000}x your
        deposit. Both go into a Perpl trading account that the protocol's contract owns: you trade it, but nobody, including you,
        can withdraw the borrowed money.
      </p>
      <div className="stats">
        <Stat label="Approved limit" value={approval.limit ? usd(approval.limit, 0) : "None"} source="CreditManager.approvals(wallet)" />
        <Stat label="Interest" value={approval.limit ? `${pct(approval.aprBps)} a year` : "-"} source="CreditManager.approvals(wallet).aprBps" />
      </div>
      {isLocalFork() && !approval.limit && (
        <div className="demo">
          <p><strong>Demo approval (local fork only).</strong> The underwriter approves this wallet for $2,000. This is not a credit score; it stands in for one because a mainnet history cannot be linked on testnet.</p>
          <ActionButton label="Approve this wallet for $2,000 (demo)" kind="secondary" run={() => forkDemoApproval(d, session.address, 2_000_000_000n)} onDone={reload} />
        </div>
      )}
      <div className="form">
        <label>Your deposit (AUSD)<input inputMode="decimal" value={deposit} onChange={(e) => setDeposit(e.target.value)} /></label>
        <label>Borrow (AUSD)<input inputMode="decimal" value={borrow} onChange={(e) => setBorrow(e.target.value)} /></label>
      </div>
      <p className="note">Trading account starts with {usd(dep + bor, 0)}. {problem ?? "Ready."}</p>
      <ActionButton label="Open credit line" disabled={!!problem} run={() => openLine(d, session.walletKey, dep, bor)} onDone={reload} />
    </section>
  );
}

function LineDashboard({ d, session, rules, btc, view, risk, reload }: {
  d: Deployment; session: Session; rules: Awaited<ReturnType<typeof readRules>>; btc: Awaited<ReturnType<typeof readBtc>>;
  view: Awaited<ReturnType<typeof readLine>>; risk: ReturnType<typeof lineRisk>; reload: () => void;
}) {
  const [side, setSide] = useState<"long" | "short">("long");
  const [size, setSize] = useState("500");
  const [lev, setLev] = useState("2");
  const [top, setTop] = useState("100");
  const [sweepAmt, setSweepAmt] = useState("");
  const priceScale = 10n ** (btc.priceDecimals + btc.lotDecimals);
  const toUsd = (pns: bigint) => Number(pns) / 10 ** Number(btc.priceDecimals);
  const lotsFor = (notional: bigint) => (notional * priceScale) / (btc.markPNS * 10n ** btc.collateralDecimals);
  const lots = lotsFor(parseUsd(size));
  const positionUsd = (view.lots * btc.markPNS * 10n ** btc.collateralDecimals) / priceScale;
  const health = Number(view.health) / 100;
  const tone = view.health >= rules.openHealthBps ? "good" : view.health >= rules.freezeHealthBps ? undefined : "bad";
  const active = view.state === 1;
  return (
    <section className="card">
      <p className="eyebrow">Your credit line</p>
      <h3>{lineStates[view.state]} line <span className="mono">{short(view.address)}</span></h3>
      <div className="health">
        <div className="health-bar"><span style={{ width: `${Math.min(100, health / 3)}%` }} className={tone ?? "warn"} /></div>
        <p className="note">
          Health {health.toFixed(0)}%: what the account is worth compared with what you owe. Below {pct(rules.openHealthBps)} you cannot add risk;
          at {pct(rules.freezeHealthBps)} anyone can freeze the line and close its positions, and the lenders are repaid first from your deposit.
        </p>
      </div>
      <div className="stats">
        <Stat label="Account worth" value={usd(view.equity)} source="CreditLine.equity()" />
        <Stat label="You owe" value={usd(view.debt)} source="CreditLine.debt()" />
        <Stat label="Health" value={`${health.toFixed(0)}%`} tone={tone} source="CreditLine.healthBps()" />
        <Stat label="BTC price" value={`$${toUsd(btc.markPNS).toLocaleString()}`} source="Perpl getPerpetualInfoV2(16).markPNS" />
        <Stat label="BTC position" value={view.lots ? `${view.isLong ? "Long" : "Short"} ${usd(positionUsd, 0)}` : "None"} source="Perpl getPositionV2(16, account)" />
        <Stat label="Frozen if BTC hits" value={risk.freeze !== null ? `$${toUsd(risk.freeze).toLocaleString()}` : "No position"} tone={risk.freeze !== null ? "bad" : undefined} source="app: equity, debt, freeze threshold, position size" />
      </div>
      {active && (
        <>
          <h4>Trade BTC</h4>
          <div className="form">
            <label>Side<select value={side} onChange={(e) => setSide(e.target.value as "long" | "short")}><option value="long">Long (BTC goes up)</option><option value="short">Short (BTC goes down)</option></select></label>
            <label>Size (AUSD)<input inputMode="decimal" value={size} onChange={(e) => setSize(e.target.value)} /></label>
            <label>Leverage<select value={lev} onChange={(e) => setLev(e.target.value)}>{[1, 2, 3].filter((x) => x * 100 <= Number(rules.maxLeverageHdths)).map((x) => <option key={x} value={x}>{x}x</option>)}</select></label>
          </div>
          <p className="note">
            Fills immediately or not at all, within {pct(rules.bandBps)} of the mark price. That is {lots.toString()} lots. Opening needs health to stay above {pct(rules.openHealthBps)} afterwards.
          </p>
          <div className="row">
            <ActionButton label={`Open ${side}`} disabled={lots === 0n} run={() => trade(d, session.walletKey, view.address, side, lots, BigInt(lev) * 100n, rules.bandBps)} onDone={reload} />
            {view.lots > 0n && (
              <ActionButton label="Close position" kind="secondary" run={() => trade(d, session.walletKey, view.address, view.isLong ? "closeLong" : "closeShort", view.lots, 100n, rules.bandBps)} onDone={reload} />
            )}
          </div>
          <h4>Add your own money</h4>
          <div className="row">
            <input aria-label="Top-up amount" inputMode="decimal" value={top} onChange={(e) => setTop(e.target.value)} />
            <ActionButton label="Top up" kind="secondary" run={() => topUp(d, session.walletKey, view.address, parseUsd(top))} onDone={reload} />
          </div>
          <h4>Take profit</h4>
          <p className="note">
            You can withdraw anything above {pct(rules.sweepHealthBps)} of what you owe, from the account's free cash. Right now that is
            up to <strong>{usd(risk.maxSweep)}</strong>. Your passkey must approve it.
          </p>
          <div className="row">
            <input aria-label="Sweep amount" inputMode="decimal" placeholder={(Number(risk.maxSweep) / 1e6).toFixed(2)} value={sweepAmt} onChange={(e) => setSweepAmt(e.target.value)} />
            <ActionButton
              label="Withdraw profit with passkey"
              disabled={risk.maxSweep === 0n}
              run={async () => {
                const amount = sweepAmt ? parseUsd(sweepAmt) : risk.maxSweep;
                const proof = await prove(d.identity, session, view.address, actions.sweep(amount));
                await wait(await walletFor(session.walletKey).writeContract({ address: view.address, abi: creditLineAbi, functionName: "sweep", args: [amount, proof] }));
              }}
              onDone={reload}
            />
          </div>
          <SessionKeys d={d} session={session} line={view.address} />
          <h4>Close the line</h4>
          <p className="note">Close positions first. Closing repays the lenders and the interest, and sends you everything left. Your passkey must approve it.</p>
          <ActionButton
            label="Close line with passkey"
            kind="secondary"
            disabled={view.lots > 0n}
            run={async () => {
              const proof = await prove(d.identity, session, view.address, actions.close());
              await wait(await walletFor(session.walletKey).writeContract({ address: view.address, abi: creditLineAbi, functionName: "close", args: [proof] }));
            }}
            onDone={reload}
          />
        </>
      )}
    </section>
  );
}


// ------------------------------------------------------------ session keys

const SESSION_STORE = "margin-line-session-key";

/** A session key lets a bot or a second device trade within caps for up to 7 days. It can never
 *  withdraw, sweep or close; the contract enforces that. Granting one needs the passkey. */
function SessionKeys({ d, session, line }: { d: Deployment; session: Session; line: Address }) {
  const keyAddr = (): Address | null => {
    try {
      const k = sessionStorage.getItem(SESSION_STORE);
      return k ? privateKeyToAccount(k as Hex).address : null;
    } catch {
      return null;
    }
  };
  const s = useLoad(async () => {
    const key = keyAddr();
    if (!key) return null;
    const [expiry, maxOrder, remaining] = await publicClient.readContract({ address: line, abi: creditLineAbi, functionName: "sessions", args: [key] });
    return { key, expiry: Number(expiry), maxOrder, remaining };
  }, [line]);
  const live = s.data && s.data.expiry > 0;
  return (
    <>
      <h4>Session key</h4>
      <p className="note">
        Let a trading bot or a second device place orders for up to a day, capped at $500 per order and $2,000 in total.
        A session key can never withdraw, take profit or close the line. Your passkey approves the grant.
      </p>
      {live && (
        <div className="stats">
          <Stat label="Session key" value={short(s.data!.key)} source="CreditLine.sessions(key)" />
          <Stat label="Expires" value={new Date(s.data!.expiry * 1000).toLocaleString()} source="sessions(key).expiry" />
          <Stat label="Order budget left" value={usd(s.data!.remaining, 0)} source="sessions(key).remainingNotional" />
        </div>
      )}
      <div className="row">
        <ActionButton
          label="Grant session key with passkey"
          kind="secondary"
          disabled={!!live}
          run={async () => {
            const pk = generatePrivateKey();
            const key = privateKeyToAccount(pk).address;
            const now = Number((await publicClient.getBlock()).timestamp);
            const expiry = now + 86_400;
            const maxOrder = 500_000_000n;
            const total = 2_000_000_000n;
            const proof = await prove(d.identity, session, line, actions.grantSession(key, expiry, maxOrder, total));
            await wait(await walletFor(session.walletKey).writeContract({ address: line, abi: creditLineAbi, functionName: "grantSession", args: [key, expiry, maxOrder, total, proof] }));
            sessionStorage.setItem(SESSION_STORE, pk);
          }}
          onDone={s.reload}
        />
        {live && (
          <ActionButton
            label="Revoke session key"
            kind="secondary"
            run={async () => {
              await wait(await walletFor(session.walletKey).writeContract({ address: line, abi: creditLineAbi, functionName: "revokeSession", args: [s.data!.key] }));
            }}
            onDone={s.reload}
          />
        )}
      </div>
    </>
  );
}
