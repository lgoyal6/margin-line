# Margin Line

Credit for onchain traders on Monad. Lenders fund proven traders on Perpl; the borrowed money sits in a
Perpl account the protocol owns, so traders can trade it but never withdraw it.

Design and build plan: [docs/DESIGN.md](docs/DESIGN.md).

## Phase 0 check

```bash
forge test --match-path test/phase0/PerplBoundary.t.sol --fork-url https://testnet-rpc.monad.xyz
forge test --match-path test/phase0/PerplBoundary.t.sol --fork-url https://rpc.monad.xyz
```

Requires Foundry 1.8+ (Monad EVM is selected for CLI forks). Fork tests only; no real transactions.

## Tests

```bash
forge test --no-match-path "test/{fork,phase0}/*"                                  # unit + invariants
forge test --match-path "test/{fork,phase0}/*" --fork-url https://testnet-rpc.monad.xyz
forge test --match-path "test/{fork,phase0}/*" --fork-url https://rpc.monad.xyz
```

## Keeper

Permissionless: freezes unhealthy lines (earning the bounty), unwinds their Perpl positions, settles.

```bash
cd keeper && npm install && KEEPER_KEY=0x... npm start
```

## Live end-to-end tests (Monad testnet)

```bash
cd e2e && npm install && npx playwright install chromium
npm run passkey-e2e                                            # passkey-only onboarding via Mera in a real browser
node --experimental-strip-types src/keeper-liveness.ts         # independent keeper freezes a live line
```

Deployed addresses: `deployments/monad-testnet.json`. Evidence from runs: `e2e/evidence/`.
AI coding tools (Claude Code) were used to write this project.
