#!/usr/bin/env bash
# Deploys the two demo apps (one per operator) and the side-by-side dashboard.
. "$(dirname "$0")/lib.sh"

log "Demo apps and dashboard"
for ns in app-vso app-eso demo-ui; do
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" create configmap app-code --from-file=app.py="$ROOT_DIR/app/app.py" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
done
ok "namespaces and app code"

# Read-only Postgres login for the dashboard's "Live users in Postgres" row.
# It can list users (pg_roles) but has no access to data and no admin rights.
[ -f "$SECRETS_DIR/pg-monitor-password" ] || { openssl rand -hex 16 > "$SECRETS_DIR/pg-monitor-password"; chmod 600 "$SECRETS_DIR/pg-monitor-password"; }
mon_pw="$(cat "$SECRETS_DIR/pg-monitor-password")"
psql_q 'DO $do$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $n$demo_monitor$n$) THEN CREATE ROLE demo_monitor LOGIN; END IF; END $do$;' >/dev/null
psql_q "ALTER ROLE demo_monitor WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$mon_pw';" >/dev/null
psql_q "GRANT CONNECT ON DATABASE demo TO demo_monitor;" >/dev/null
k -n demo-ui create secret generic postgres-monitor --from-literal=password="$mon_pw" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
ok "read-only Postgres login for the dashboard"

apply_dir "$ROOT_DIR/k8s/app-vso" >/dev/null && ok "app-vso: VaultConnection, VaultAuth, 3 secrets, app"
apply_dir "$ROOT_DIR/k8s/app-eso" >/dev/null && ok "app-eso: SecretStore, 2 generators, 3 ExternalSecrets, app"
k apply -f "$ROOT_DIR/k8s/platform/dashboard.yaml" >/dev/null && ok "dashboard"

# Restart the pods when app.py changes (a ConfigMap update alone doesn't restart them).
code_sha="$(openssl dgst -sha256 "$ROOT_DIR/app/app.py" | awk '{print substr($NF,1,16)}')"
patch="{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"demo/app-code\":\"$code_sha\"}}}}}"
k -n app-vso patch deploy/app -p "$patch" >/dev/null
k -n app-eso patch deploy/app -p "$patch" >/dev/null
k -n demo-ui patch deploy/dashboard -p "$patch" >/dev/null
ok "app code version $code_sha"

for ns in app-vso app-eso; do
  k -n "$ns" rollout status deploy/app --timeout=240s >/dev/null \
    || die "$ns/app didn't become ready. Check: kubectl --context $KCTX -n $ns get events --sort-by=.lastTimestamp"
  ok "$ns/app ready"
done
k -n demo-ui rollout status deploy/dashboard --timeout=120s >/dev/null && ok "dashboard ready"
