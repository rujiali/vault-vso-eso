#!/usr/bin/env bash
# Installs Vault Enterprise, initialises it (1 key share — lab only) and unseals it.
. "$(dirname "$0")/lib.sh"

log "Vault Enterprise ($VAULT_ENT_TAG)"
mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"

k create namespace vault --dry-run=client -o yaml | k apply -f - >/dev/null
k -n vault create secret generic vault-ent-license --from-file=license="$LICENSE_FILE" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
ok "licence secret"

helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
h upgrade --install vault hashicorp/vault -n vault \
  -f "$ROOT_DIR/helm/vault-values.yaml" \
  --set server.image.tag="$VAULT_ENT_TAG" >/dev/null
ok "helm release 'vault'"

# vault-0 won't be Ready until it's initialised and unsealed, so wait for Running, then for the API.
phase=""
for _ in $(seq 1 120); do
  phase="$(k -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Running" ] && break
  sleep 2
done
[ "$phase" = "Running" ] || die "vault-0 didn't start. Check: kubectl --context $KCTX -n vault describe pod vault-0
(an image pull error usually means VAULT_ENT_TAG doesn't exist — set it in lab.env)"

for _ in $(seq 1 60); do
  rc=0; k -n vault exec vault-0 -- vault status >/dev/null 2>&1 || rc=$?
  [ "$rc" != 1 ] && break   # 0 = unsealed, 2 = sealed; 1 = not answering yet
  sleep 2
done
ok "vault-0 running"

initialized="$(k -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r .initialized || true)"
if [ "$initialized" = "false" ]; then
  k -n vault exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json \
    > "$SECRETS_DIR/vault-init.json"
  chmod 600 "$SECRETS_DIR/vault-init.json"
  ok "initialised — keys and root token in .secrets/vault-init.json"
elif [ ! -f "$SECRETS_DIR/vault-init.json" ]; then
  die "Vault is already initialised but .secrets/vault-init.json is missing. Run scripts/down.sh and start again."
else
  ok "already initialised"
fi

"$ROOT_DIR/scripts/unseal.sh"
