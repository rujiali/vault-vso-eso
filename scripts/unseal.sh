#!/usr/bin/env bash
# Unseals vault-0. Run this after the Podman machine or the Vault pod restarts.
. "$(dirname "$0")/lib.sh"

log "Unseal Vault"
key="$(jq -r '.unseal_keys_b64[0]' "$SECRETS_DIR/vault-init.json")"
sealed="$(k -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed || true)"
if [ "$sealed" = "true" ]; then
  k -n vault exec vault-0 -- vault operator unseal "$key" >/dev/null
  ok "unsealed"
else
  ok "already unsealed"
fi

k -n vault wait --for=condition=Ready pod/vault-0 --timeout=120s >/dev/null
for _ in $(seq 1 30); do
  curl -fsS "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 \
  || die "Vault is unsealed but $VAULT_ADDR isn't answering from your Mac. Is port 8200 already in use?"
ok "Vault reachable at $VAULT_ADDR"
