# Margin Line app

A Vite + React + viem client with four pages, all reading and writing the real contracts:

| Page | What a person can do |
|---|---|
| Trade | Create an account with a passkey (no seed phrase); register it onchain; look up any Perpl account's score and have the oracle contract confirm it; open a credit line; trade BTC on Perpl; see health and the BTC price that would freeze the line; top up; take profit and close the line, each approved by the passkey; grant and revoke a capped session key |
| Lend | See both tranches with live numbers; deposit; withdraw instantly from idle cash; join the withdrawal queue and see how much is ahead; cancel |
| Curate | See every risk rule; tighten one instantly; propose a riskier one, which waits out the public timelock; run or veto proposals; stress the open book with a BTC price move through the RiskLens contract |
| Explore | Every line, its state, health, freezes and keeper bounties, and pool totals |

Every figure names the contract call or event it came from, under the number.

## Run it locally

```bash
app/scripts/local-chain.sh      # fork Monad testnet, deploy, seed $100,000, publish and finalize score epoch 1
app/scripts/fork-mark.sh        # keep the fork's BTC price equal to live testnet (leave running)
npm --prefix app run dev -- --port 5180
```

Open http://localhost:5180 (a hostname, not 127.0.0.1: passkeys need one).

## Tests

```bash
node --experimental-strip-types app/scripts/risk.test.ts   # freeze price and max sweep vs hand calculations
node --experimental-strip-types e2e/src/newcomer.ts        # Phase 7 exit test, see below
node --experimental-strip-types e2e/src/roles.ts           # lender, curator, explorer and stress checks
```

`e2e/src/newcomer.ts` uses a real browser with a virtual passkey and only clicks visible buttons:
create account, test funds, register passkey, check a score (verified onchain), demo approval, open a
line, grant and revoke a session key, open and close a BTC long on Perpl's book, take profit with the
passkey, close the line with the passkey, lend to junior. It then checks onchain that the profit
arrived, the line is closed, the pool was repaid with zero loss, and the junior deposit exists. It
passed twice in a row from a fresh fork; screenshots and `result.json` are in `e2e/evidence/newcomer/`.

`e2e/src/roles.ts` builds a market (two $25,000 lines, a fully borrowed line holding $10,000 of BTC,
a line frozen by a keeper and settled, a lender already queued), then drives Lend and Curate in the
browser and compares every Explore figure, the queue position and the stress panel with direct
contract reads. Evidence in `e2e/evidence/roles/`.

## What is real and what is local

| Real | Local-fork only, and labeled in the UI |
|---|---|
| All contracts, deployed by `script/Deploy.s.sol` through `MarketFactory` | The chain is an anvil fork of Monad testnet |
| Perpl's real exchange, order book and DelegatedAccount factory | "Get test funds": MON and AUSD given to the wallet by impersonation |
| Passkey wallet (Mera PRF) and onchain P-256 verification of every approval | "Demo approval": the underwriter approves $2,000, because a mainnet score cannot be linked on testnet |
| Score epoch built from real Perpl mainnet history, finalized and verified on the oracle | Perpl's BTC oracle check is switched off on the fork and its mark is copied from live testnet every 30 s (`fork-mark.sh`) |
| Curator actions run through RiskCurator's real tighten and timelock paths | The curator and guardian act by impersonation |

Known limits: the session lives in the browser tab (sessionStorage), which is a demo convenience; a
production app re-derives the wallet from the passkey on each visit. Scores come from mainnet while
loans are on testnet, so the score check and the line are separate steps here.
