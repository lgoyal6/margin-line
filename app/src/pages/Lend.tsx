import { useState } from "react";
import type { Address } from "viem";
import { isLocalFork, type Deployment } from "../chain";
import { loadSession } from "../passkey";
import { cancelRequest, deposit, forkFund, processQueue, readMarket, readTranche, requestRedeem, withdraw } from "../protocol";
import { ActionButton, Stat, parseUsd, pct, usd, useLoad } from "../ui";
import evidence from "../../../docs/evidence/backtest-h7.json";

export function Lend({ d }: { d: Deployment }) {
  const session = loadSession();
  const market = useLoad(() => readMarket(d), []);
  const m = market.data;
  return (
    <div className="stack">
      <section className="card">
        <p className="eyebrow">Lend</p>
        <h3>Earn interest from proven traders</h3>
        <p className="muted">
          Your money is lent to traders whose history passed the credit rules, and it sits in trading accounts they
          cannot withdraw from. If a trader loses, their own deposit pays first. Then the reserve, then junior lenders,
          and senior lenders last.
        </p>
        {m && (
          <div className="stats">
            <Stat label="Lent out" value={`${usd(m.outstanding, 0)} (${pct(m.utilization)})`} source="CreditPool.principalOutstanding, utilizationBps" />
            <Stat label="Cash on hand" value={usd(m.idle, 0)} source="CreditPool.idle()" />
            <Stat label="Reserve" value={usd(m.reserve)} source="CreditPool.reserve()" />
            <Stat label="Junior share" value={pct(m.juniorBps)} source={`CreditPool.juniorBps (min ${pct(m.minJunior)})`} />
            <Stat label="Interest earned" value={usd(m.interest)} source="CreditPool.totalInterestEarned" />
            <Stat label="Losses" value={usd(m.losses)} tone={m.losses ? "bad" : undefined} source="CreditPool.totalLosses" />
          </div>
        )}
        <p className="note">
          Evidence behind the credit rules: on real Perpl history, approved traders were liquidated within a week
          {" "}{(evidence.approved_liq_rate * 100).toFixed(1)}% of the time, against {(evidence.denied_liq_rate * 100).toFixed(1)}% for everyone else
          ({evidence.trader_checkpoints.toLocaleString()} trader-weeks).
        </p>
        {isLocalFork() && session && (
          <ActionButton label="Get test funds (local fork)" kind="secondary" run={() => forkFund(d, session.address, 5_000_000_000n)} />
        )}
      </section>
      <div className="split">
        <Tranche d={d} vault={d.seniorVault} name="Senior" pitch={`Paid first: a target of ${m ? pct(m.seniorApr) : "8%"} a year, and loses money only after the reserve and every junior dollar are gone.`} onChange={market.reload} />
        <Tranche d={d} vault={d.juniorVault} name="Junior" pitch="Takes losses before senior, and earns everything left after senior's target and the reserve. Higher risk, higher upside." onChange={market.reload} />
      </div>
    </div>
  );
}

function Tranche({ d, vault, name, pitch, onChange }: { d: Deployment; vault: Address; name: string; pitch: string; onChange: () => void }) {
  const session = loadSession();
  const t = useLoad(() => readTranche(d, vault, session?.address ?? null), [vault, session?.address]);
  const [amount, setAmount] = useState("1000");
  const done = () => { t.reload(); onChange(); };
  const x = t.data;
  return (
    <section className={`card tranche-card ${name.toLowerCase()}`}>
      <h3>{name}</h3>
      <p className="muted">{pitch}</p>
      {x && (
        <div className="stats">
          <Stat label="Tranche size" value={usd(x.assets, 0)} source={`${name}Vault.totalAssets()`} />
          <Stat label="Value of 1 share" value={usd(x.sharePrice, 6)} source={`${name}Vault.convertToAssets(1e12)`} />
          <Stat label="Can still take" value={x.maxDeposit === null ? "No limit" : usd(x.maxDeposit, 0)} source={`${name}Vault.maxDeposit`} />
          <Stat label="Waiting to withdraw" value={`${(Number(x.queueLength) - Number(x.head))} requests`} source={`${name}Vault.queueLength - head`} />
        </div>
      )}
      {!session ? (
        <p className="note">Create an account on the Trade page to lend.</p>
      ) : x && (
        <>
          <div className="stats">
            <Stat label="Your shares are worth" value={usd(x.mine.value)} source={`${name}Vault.convertToAssets(balanceOf(you))`} />
            <Stat label="Withdraw now, up to" value={usd(x.mine.maxWithdraw)} source={`${name}Vault.maxWithdraw(you)`} />
          </div>
          <div className="row">
            <input aria-label={`${name} amount`} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
            <ActionButton label="Deposit" run={() => deposit(d, session.walletKey, vault, parseUsd(amount))} onDone={done} />
            <ActionButton label="Withdraw now" kind="secondary" disabled={!x.mine.maxWithdraw} run={() => withdraw(session.walletKey, vault, parseUsd(amount))} onDone={done} />
          </div>
          <p className="note">
            Instant withdrawals use cash that is not lent out. When most is lent, join the queue: requests are paid in
            order as traders repay, and your shares keep earning (or losing) until paid.
          </p>
          <div className="row">
            <ActionButton label="Queue all my shares" kind="secondary" disabled={!x.mine.shares} run={() => requestRedeem(session.walletKey, vault, x.mine.shares)} onDone={done} />
            <ActionButton label="Pay the queue now" kind="secondary" run={() => processQueue(session.walletKey, vault)} onDone={done} />
          </div>
          {x.requests.map((r) => (
            <div className="queue-item" key={r.id}>
              <span>Request #{r.id}: {usd(r.value)}, with {usd(r.ahead)} ahead of you</span>
              <ActionButton label="Cancel" kind="secondary" run={() => cancelRequest(session.walletKey, vault, BigInt(r.id))} onDone={done} />
            </div>
          ))}
        </>
      )}
      {t.error && <p className="action-error">{t.error}</p>}
    </section>
  );
}
