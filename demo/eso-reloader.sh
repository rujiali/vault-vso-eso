#!/usr/bin/env bash
# Optional "fair fight": give ESO what it needs to restart the app — Stakater Reloader.
# Use it to make the point that ESO *can* do this, with one more component to accredit and patch.
#   demo/eso-reloader.sh          install Reloader and annotate the ESO app
#   demo/eso-reloader.sh remove   take it away again
. "$(dirname "$0")/../scripts/lib.sh"

if [ "${1:-}" = "remove" ]; then
  k -n app-eso annotate deploy/app reloader.stakater.com/auto- >/dev/null 2>&1 || true
  h uninstall reloader -n reloader >/dev/null 2>&1 || true
  ok "Reloader removed"
  exit 0
fi

log "Installing Stakater Reloader"
helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null 2>&1 || true
helm repo update stakater >/dev/null
h upgrade --install reloader stakater/reloader -n reloader --create-namespace --wait >/dev/null
k -n app-eso annotate deploy/app reloader.stakater.com/auto="true" --overwrite >/dev/null
ok "ESO app will now restart when its Secrets change"
