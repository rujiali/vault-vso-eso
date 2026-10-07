#!/usr/bin/env bash
# Builds the whole lab. Safe to re-run: each stage skips what already exists.
. "$(dirname "$0")/lib.sh"
S="$ROOT_DIR/scripts"

"$S/preflight.sh"
"$S/00-cluster.sh"
"$S/10-vault.sh"
"$S/20-postgres.sh"
"$S/30-terraform.sh"
"$S/40-operators.sh"
"$S/50-apps.sh"

log "Lab is up"
cat <<EOF

    Dashboard   http://localhost:8080
    Vault UI    http://localhost:8200/ui   (namespace: $VAULT_NS)
    Root token  jq -r .root_token .secrets/vault-init.json

    Next: open RUNSHEET.md. Start demo/leases.sh in a second terminal.
EOF
