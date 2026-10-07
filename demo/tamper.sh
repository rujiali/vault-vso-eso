#!/usr/bin/env bash
# Scenario 6 — someone with kubectl edits the synced Secret. Does the operator put it back?
#   demo/tamper.sh vso | eso
# REHEARSE THIS: recent ESO versions also watch their target Secrets. If both restore it,
# present it as parity, not a VSO advantage.
. "$(dirname "$0")/../scripts/lib.sh"

side="${1:-}"; [ "$side" = vso ] || [ "$side" = eso ] || die "usage: $0 vso|eso"
ns="app-$side"
rogue="$(printf 'tampered-by-kubectl' | base64)"

val() { k -n "$ns" get secret app-config -o jsonpath='{.data.message}' 2>/dev/null | base64 -d 2>/dev/null; }

log "$(upper "$side"): overwriting $ns/app-config with a rogue value"
k -n "$ns" patch secret app-config --type merge -p "{\"data\":{\"message\":\"$rogue\"}}" >/dev/null
for i in $(seq 1 30); do
  cur="$(val)"
  printf '    t+%2ss  %s\n' "$i" "$cur"
  if [ "$cur" != "tampered-by-kubectl" ]; then ok "restored after ~${i}s"; exit 0; fi
  sleep 1
done
warn "Still tampered after 30s — it will only be corrected on the next scheduled refresh."
