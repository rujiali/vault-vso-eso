#!/usr/bin/env bash
# Scenarios 1 and 5 — ground truth for dynamic database credentials:
# live Vault leases and live Postgres users, per operator. Refreshes every 3s.
#   demo/leases.sh          keep watching
#   demo/leases.sh --once   print once
. "$(dirname "$0")/../scripts/lib.sh"

show() {
  printf '\033[1mDynamic Postgres credentials\033[0m   %s\n\n' "$(date '+%H:%M:%S')"
  for side in vso eso; do
    leases="$(v list -format=json "sys/leases/lookup/database/creds/app-$side/" 2>/dev/null | jq 'length' 2>/dev/null || true)"
    users="$(psql_q "select count(*) from pg_roles where rolname like 'v-app-${side}-%'" 2>/dev/null | tr -d '[:space:]' || true)"
    printf '  \033[1m%s\033[0m   Vault leases: %-3s  Postgres users: %-3s\n' "$(upper "$side")" "${leases:-0}" "${users:-?}"
    psql_q "select '        ' || rolname || '   valid until ' || to_char(rolvaliduntil at time zone 'UTC', 'HH24:MI:SS') || ' UTC'
            from pg_roles where rolname like 'v-app-${side}-%' order by rolvaliduntil" 2>/dev/null || true
    echo
  done
}

if [ "${1:-}" = "--once" ]; then show; exit 0; fi
while true; do
  out="$(show)"
  clear
  printf '%s\n' "$out"
  sleep 3
done
