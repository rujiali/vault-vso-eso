#!/usr/bin/env bash
# Shared settings and helpers for the ESO vs VSO lab.
# Override any setting in your shell, or put overrides in ./lab.env (see lab.env.example).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT_DIR/lab.env" ]; then . "$ROOT_DIR/lab.env"; fi

export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
CLUSTER_NAME="${CLUSTER_NAME:-eso-vso}"
KCTX="kind-${CLUSTER_NAME}"

VAULT_ENT_TAG="${VAULT_ENT_TAG:-2.1.0-ent}"      # hashicorp/vault-enterprise image tag
VSO_CHART_VERSION="${VSO_CHART_VERSION:-1.6.0}"  # Vault Secrets Operator
ESO_CHART_VERSION="${ESO_CHART_VERSION:-}"       # External Secrets Operator; empty = latest (pin after rehearsal)
VAULT_NS="${VAULT_NS:-demo}"             # Vault Enterprise namespace used by the demo

LICENSE_FILE="${LICENSE_FILE:-$ROOT_DIR/license/vault.hclic}"
SECRETS_DIR="$ROOT_DIR/.secrets"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

k() { kubectl --context "$KCTX" "$@"; }
h() { helm --kube-context "$KCTX" "$@"; }

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

root_token() {
  [ -f "$SECRETS_DIR/vault-init.json" ] || die "No $SECRETS_DIR/vault-init.json — run scripts/up.sh first."
  jq -r .root_token "$SECRETS_DIR/vault-init.json"
}

# Run the vault CLI inside the Vault pod, in the demo namespace, as root.
# No local vault binary needed, and the clock is the cluster's clock.
v() {
  k -n vault exec vault-0 -- env VAULT_TOKEN="$(root_token)" VAULT_NAMESPACE="$VAULT_NS" vault "$@"
}
vsh() {
  k -n vault exec vault-0 -- env VAULT_TOKEN="$(root_token)" VAULT_NAMESPACE="$VAULT_NS" sh -c "$1"
}

psql_q() { k -n db exec deploy/postgres -- psql -U vault -d demo -tAc "$1"; }

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Apply a manifest directory, substituting the Vault namespace on lines marked "# vault-namespace".
apply_dir() {
  for f in "$1"/*.yaml; do
    sed -E "s/^([[:space:]]*namespace:)[[:space:]]+[^[:space:]]+([[:space:]]+# vault-namespace.*)$/\1 ${VAULT_NS}\2/" "$f" | k apply -f -
  done
}
