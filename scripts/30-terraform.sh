#!/usr/bin/env bash
# Configures Vault with Terraform: namespace, KV, database, PKI, transit, Kubernetes auth, policies.
. "$(dirname "$0")/lib.sh"

log "Terraform: Vault configuration in namespace '$VAULT_NS'"
export TF_VAR_vault_addr="$VAULT_ADDR"
export TF_VAR_vault_token; TF_VAR_vault_token="$(root_token)"
export TF_VAR_pg_password; TF_VAR_pg_password="$(cat "$SECRETS_DIR/pg-password")"
export TF_VAR_vault_namespace="$VAULT_NS"

cd "$ROOT_DIR/terraform" || die "no terraform directory"
terraform init -input=false -upgrade >/dev/null
terraform apply -input=false -auto-approve
ok "Vault configured"
