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
