#!/usr/bin/env bash
# Creates the kind cluster on Podman.
. "$(dirname "$0")/lib.sh"

log "kind cluster '$CLUSTER_NAME' (provider: $KIND_EXPERIMENTAL_PROVIDER)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "already exists"
else
  kind create cluster --name "$CLUSTER_NAME" --config "$ROOT_DIR/kind/cluster.yaml" --wait 180s
fi
k get nodes -o wide
