#!/usr/bin/env bash
# Local fork only: keep Perpl's BTC mark price current by copying the live Monad testnet mark onto
# the fork every 30 seconds. A fork freezes Perpl's prices at the moment it was taken while its clock
# keeps running, and TradeGuard rightly refuses marks older than 10 minutes. Uses anvil impersonation
# of Perpl's owner, which exists only on the fork. Run after app/scripts/local-chain.sh.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
FORK="http://127.0.0.1:8547"
LIVE="${LIVE_RPC:-https://testnet-rpc.monad.xyz}"
EX="0x1964C32f0bE608E7D29302AFF5E61268E72080cc"
PERP=16
SIG="getPerpetualInfoV2(uint256)((string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256))"
OWNER="$(cast call "$EX" "owner()(address)" --rpc-url "$FORK")"
cast rpc anvil_impersonateAccount "$OWNER" --rpc-url "$FORK" >/dev/null
cast rpc anvil_setBalance "$OWNER" 0x56BC75E2D63100000 --rpc-url "$FORK" >/dev/null
while true; do
  mark="$(cast call "$EX" "$SIG" "$PERP" --rpc-url "$LIVE" 2>/dev/null | tr ',' '\n' | sed -n 12p | awk '{print $1}')"
  if [[ -n "$mark" ]] && cast send "$EX" "updateMarkPricePNSByOwner(uint256,uint32)" "$PERP" "$mark" \
      --from "$OWNER" --unlocked --rpc-url "$FORK" >/dev/null 2>&1; then
    echo "$(date '+%H:%M:%S') BTC mark on fork set to live testnet mark $mark"
  else
    echo "$(date '+%H:%M:%S') could not refresh the mark (live RPC or fork unavailable); retrying"
  fi
  sleep 30
done
