#!/usr/bin/env bash
# Scenario 2 — rotate the KV secret. The value embeds the rotation time (from the cluster's
# clock), so the dashboard can time how long each operator takes.
. "$(dirname "$0")/../scripts/lib.sh"

vsh 'vault kv put -mount=kv app/config message="rotated-$(date +%s)"' >/dev/null
ok "kv/app/config rotated at $(date '+%H:%M:%S') — watch the dashboard"
