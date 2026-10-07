#!/usr/bin/env bash
# Checks that Vault delivers KV change events to a subscriber with VSO's policy (app-vso).
# Subscribes twice while writing to kv/app/config: once with a token holding the app-vso
# policy, once with the root token. Compare the two to tell a policy problem from an
# events problem. Note: this rotates kv/app/config twice.
. "$(dirname "$0")/../scripts/lib.sh"

try() {
  label="$1"; token="$2"
  out="$(mktemp)"
  k -n vault exec vault-0 -- env VAULT_TOKEN="$token" VAULT_NAMESPACE="$VAULT_NS" \
    timeout 15 vault events subscribe 'kv*' >"$out" 2>&1 &
  pid=$!
  sleep 4
  vsh 'vault kv put -mount=kv app/config message="rotated-$(date +%s)"' >/dev/null
  sleep 6
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if grep -q '"event_type"\|kv-v2/data-write' "$out"; then
    ok "$label: event received"; rc=0
  else
    warn "$label: no event received"; sed 's/^/        /' "$out" | head -5; rc=1
  fi
  rm -f "$out"; return $rc
}

log "Checking Vault KV events in namespace $VAULT_NS"
vso_token="$(v token create -policy=app-vso -ttl=5m -field=token)"
vso=0; try "Token with VSO's policy (app-vso)" "$vso_token" || vso=1
root=0; try "Root token" "$(root_token)" || root=1

echo
if [ $vso = 0 ]; then
  ok "Events reach VSO's policy. If the dashboard still lags, restart VSO: kubectl --context $KCTX -n vault-secrets-operator-system rollout restart deploy/vault-secrets-operator-controller-manager"
elif [ $root = 0 ]; then
  warn "Vault sends events, but VSO's policy filters them out. Check the app-vso policy in terraform/policies.tf, then run scripts/30-terraform.sh."
else
  warn "No events at all, even for root. Event notifications aren't working on this Vault build."
fi
