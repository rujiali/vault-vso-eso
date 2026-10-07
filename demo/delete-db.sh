#!/usr/bin/env bash
# Scenario 1 — delete the dynamic-credential resource and see what happens to the credential.
#   demo/delete-db.sh vso    deletes the VaultDynamicSecret
#   demo/delete-db.sh eso    deletes the ExternalSecret
# Put things back with demo/restore.sh
. "$(dirname "$0")/../scripts/lib.sh"

case "${1:-}" in
  vso) log "Deleting VaultDynamicSecret app-vso/db-creds"; k -n app-vso delete vaultdynamicsecrets.secrets.hashicorp.com db-creds ;;
  eso) log "Deleting ExternalSecret app-eso/db-creds";     k -n app-eso delete externalsecret db-creds ;;
  *)   die "usage: $0 vso|eso" ;;
esac

sleep 5
"$(dirname "$0")/leases.sh" --once
