#!/usr/bin/env bash
# Tears the lab down completely: cluster, Vault keys, Terraform state.
. "$(dirname "$0")/lib.sh"

log "Deleting kind cluster '$CLUSTER_NAME'"
kind delete cluster --name "$CLUSTER_NAME" || true
rm -rf "$SECRETS_DIR"
rm -f "$ROOT_DIR"/terraform/terraform.tfstate "$ROOT_DIR"/terraform/terraform.tfstate.backup
ok "cluster, .secrets and Terraform state removed"
