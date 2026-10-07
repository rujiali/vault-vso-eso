#!/usr/bin/env bash
# Scenario 5 — kill the VSO controller mid-flight. With the encrypted client cache it comes back
# holding the same leases: same DB credential, no new Postgres user, nothing orphaned.
. "$(dirname "$0")/../scripts/lib.sh"
NS=vault-secrets-operator-system

count() { psql_q "select count(*) from pg_roles where rolname like 'v-app-vso-%'" | tr -d '[:space:]'; }
cur()   { k -n app-vso get secret db-creds -o jsonpath='{.data.username}' | base64 -d; }

before_user="$(cur)"; before_n="$(count)"
log "Before: app-vso credential $before_user  ($before_n VSO-issued Postgres user(s))"

log "Killing the VSO controller pod"
for p in $(k -n "$NS" get pods -o name | grep controller-manager); do
  k -n "$NS" delete "$p" --wait=false
done
sleep 3
k -n "$NS" rollout status deploy/vault-secrets-operator-controller-manager --timeout=180s
log "Controller back — letting it reconcile"
sleep 15

after_user="$(cur)"; after_n="$(count)"
log "After:  app-vso credential $after_user  ($after_n VSO-issued Postgres user(s))"
if [ "$before_user" = "$after_user" ] && [ "$before_n" = "$after_n" ]; then
  ok "Same credential, no new database user — the restarted operator resumed its existing lease."
else
  warn "Credential changed — check the client cache settings in helm/vso-values.yaml and the VSO logs."
fi
