#!/usr/bin/env bash
set -euo pipefail

# Start a disposable Monad testnet fork and deploy the current local stack.
# This script never connects to a live chain for writes.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RPC_URL="http://127.0.0.1:8547"
PORT="8547"
ANVIL_LOG="$ROOT/.agent-work/logs/anvil-local-chain.log"
DEPLOYMENTS_OUT="$ROOT/deployments/local-fork.json"
EXCHANGE="0x1964C32f0bE608E7D29302AFF5E61268E72080cc"
AUSD="0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC"

# The first three deterministic Anvil accounts are convenient demo wallets.
DEMO_WALLETS=(
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
)

mkdir -p "$ROOT/.agent-work/logs" "$ROOT/deployments"

# Cleanly replace any fork currently listening on the app port.
if command -v lsof >/dev/null 2>&1; then
  port_pids="$(lsof -ti tcp:"$PORT" || true)"
  if [[ -n "$port_pids" ]]; then
    kill $port_pids || true
  fi
fi
sleep 1
rm -f "$DEPLOYMENTS_OUT"

export PATH="$HOME/.foundry/bin:$PATH"
cd "$ROOT"

anvil --fork-url https://testnet-rpc.monad.xyz --port "$PORT" --code-size-limit 131072 >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!

cleanup() {
  if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
    return
  fi
  # Keep the fork alive for the app after this command finishes.
  disown "$ANVIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..60}; do
  if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
cast chain-id --rpc-url "$RPC_URL" >/dev/null

# Seed the deployer before running Deploy.s.sol. The deployment script normally
# uses the public faucet, whose frequency limit makes it unsuitable for a fresh
# fork. This impersonation exists only inside Anvil.
cast rpc anvil_impersonateAccount "$EXCHANGE" --rpc-url "$RPC_URL" >/dev/null
cast rpc anvil_setBalance "$EXCHANGE" 0x3635C9ADC5DEA000000000000000 --rpc-url "$RPC_URL" >/dev/null
cast send "$AUSD" "transfer(address,uint256)" "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" 101000000000 \
  --from "$EXCHANGE" --unlocked --rpc-url "$RPC_URL" >/dev/null

# 100,000 AUSD of starting liquidity (30% junior, 70% senior), so demo lines fit the 25% per-line cap.
SEED_LIQUIDITY=100000000000 DEPLOYMENTS_OUT="$DEPLOYMENTS_OUT" forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --code-size-limit 131072 \
  --slow \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Give the Exchange permission to send its forked AUSD balance, then fund each
# deterministic demo wallet. anvil_setBalance is local-node state only.
for wallet in "${DEMO_WALLETS[@]}"; do
  cast rpc anvil_setBalance "$wallet" 0x3635C9ADC5DEA000000000000000 --rpc-url "$RPC_URL" >/dev/null
  cast send "$AUSD" "transfer(address,uint256)" "$wallet" 1000000000 \
    --from "$EXCHANGE" --unlocked --rpc-url "$RPC_URL" >/dev/null
done

MANAGER="$(jq -r .manager "$DEPLOYMENTS_OUT")"
EXPECTED_POOL="$(jq -r .pool "$DEPLOYMENTS_OUT")"
ACTUAL_POOL="$(cast call "$MANAGER" "pool()(address)" --rpc-url "$RPC_URL")"
ACTUAL_POOL_NORMALIZED="$(printf '%s' "$ACTUAL_POOL" | tr '[:upper:]' '[:lower:]')"
EXPECTED_POOL_NORMALIZED="$(printf '%s' "$EXPECTED_POOL" | tr '[:upper:]' '[:lower:]')"
if [[ "$ACTUAL_POOL_NORMALIZED" != "$EXPECTED_POOL_NORMALIZED" ]]; then
  echo "manager pool mismatch: expected $EXPECTED_POOL, got $ACTUAL_POOL" >&2
  exit 1
fi

# Publish score epoch 1 from real Perpl mainnet history (blocks up to 112,140,000): build the tree,
# propose it with the publisher's bond, let the one-day challenge window pass on the fork, finalize.
ORACLE="$(jq -r .scoreOracle "$DEPLOYMENTS_OUT")"
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
EPOCH_FILE="$ROOT/.agent-work/epochs/10143-$(printf '%s' "$ORACLE" | tr '[:upper:]' '[:lower:]')-1.json"
SCORER_PRIVATE_KEY="$DEPLOYER_KEY" "$ROOT/.agent-work/venv/bin/python" -m scorer.epoch 1 --chain-id 10143 \
  --oracle "$ORACLE" --cutoff-block 112140000 --propose --bond 100000000000000000 --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_increaseTime 86401 --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
cast send "$ORACLE" "finalize(uint256)" 1 --private-key "$DEPLOYER_KEY" --rpc-url "$RPC_URL" >/dev/null
"$ROOT/.agent-work/venv/bin/python" -m scorer.verify_onchain "$EPOCH_FILE" --rpc-url "$RPC_URL" >/dev/null

# Perpl checks its BTC oracle is under a minute old, which a fork (whose clock just jumped a day to
# finalize the epoch) can never satisfy. On the fork only, Perpl's owner switches that check off for
# BTC; app/scripts/fork-mark.sh then keeps the mark equal to the live testnet mark.
PERPL_OWNER="$(cast call "$EXCHANGE" "owner()(address)" --rpc-url "$RPC_URL")"
cast rpc anvil_impersonateAccount "$PERPL_OWNER" --rpc-url "$RPC_URL" >/dev/null
cast rpc anvil_setBalance "$PERPL_OWNER" 0x56BC75E2D63100000 --rpc-url "$RPC_URL" >/dev/null
cast send "$EXCHANGE" "setIgnOracle(uint256,bool)" 16 true --from "$PERPL_OWNER" --unlocked --rpc-url "$RPC_URL" >/dev/null

# The app reads these two files.
mkdir -p "$ROOT/app/public/deployments" "$ROOT/app/public/epochs"
cp "$DEPLOYMENTS_OUT" "$ROOT/app/public/deployments/local-fork.json"
cp "$EPOCH_FILE" "$ROOT/app/public/epochs/latest.json"

echo "Local fork ready at $RPC_URL"
echo "Score epoch 1: finalized and verified onchain"
echo "Now run app/scripts/fork-mark.sh in another terminal to keep the BTC price current"
echo "Deployment: $DEPLOYMENTS_OUT"
echo "Manager: $MANAGER"
echo "Pool: $EXPECTED_POOL"
