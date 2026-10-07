#!/usr/bin/env bash
# Re-applies both sides' manifests after a destructive scenario.
. "$(dirname "$0")/../scripts/lib.sh"

apply_dir "$ROOT_DIR/k8s/app-vso" >/dev/null
apply_dir "$ROOT_DIR/k8s/app-eso" >/dev/null
ok "both sides re-applied — give it ~20s to settle"
