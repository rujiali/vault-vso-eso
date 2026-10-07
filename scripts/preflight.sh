#!/usr/bin/env bash
# Checks tools, the Podman machine and the licence before anything is created.
. "$(dirname "$0")/lib.sh"

log "Preflight"

missing=0
for c in podman kind kubectl helm terraform jq curl openssl; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else warn "$c not found  (brew install $c)"; missing=1; fi
done
[ "$missing" = 0 ] || die "Install the missing tools above, then re-run."

if [ "$(uname -s)" = "Darwin" ]; then
  info="$(podman machine inspect 2>/dev/null || true)"
  [ -n "$info" ] || die "No Podman machine. Create one:
    podman machine init --rootful --cpus 4 --memory 8192 && podman machine start"

  state="$(printf '%s' "$info"   | jq -r '.[0].State // empty')"
  rootful="$(printf '%s' "$info" | jq -r '.[0].Rootful // empty')"
  cpus="$(printf '%s' "$info"    | jq -r '.[0].Resources.CPUs // 0')"
  mem="$(printf '%s' "$info"     | jq -r '.[0].Resources.Memory // 0')"

  [ "$state" = "running" ] || die "Podman machine isn't running (state: ${state:-unknown}). Run: podman machine start"
  [ "$rootful" = "true" ]  || die "Podman machine is rootless; kind needs rootful:
    podman machine stop && podman machine set --rootful && podman machine start"
  ok "Podman machine running, rootful"

  if [ "$cpus" -ge 4 ] 2>/dev/null; then ok "$cpus CPUs"; else warn "$cpus CPUs — 4 or more recommended (podman machine set --cpus 4)"; fi
  if [ "$mem" -ge 8000 ] 2>/dev/null; then ok "$mem MiB RAM"; else warn "$mem MiB RAM — 8192 recommended (podman machine set --memory 8192)"; fi
fi

[ "$KIND_EXPERIMENTAL_PROVIDER" = "podman" ] && ok "kind provider: podman"

if [ -f "$LICENSE_FILE" ]; then ok "Vault Enterprise licence found"; else
  die "Put your Vault Enterprise licence at: $LICENSE_FILE"
fi
