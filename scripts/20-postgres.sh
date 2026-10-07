#!/usr/bin/env bash
# Postgres for the database secrets engine. Ephemeral storage: rebuilt with the lab.
. "$(dirname "$0")/lib.sh"

log "Postgres"
mkdir -p "$SECRETS_DIR"
[ -f "$SECRETS_DIR/pg-password" ] || { openssl rand -hex 16 > "$SECRETS_DIR/pg-password"; chmod 600 "$SECRETS_DIR/pg-password"; }

k create namespace db --dry-run=client -o yaml | k apply -f - >/dev/null
k -n db create secret generic postgres --from-literal=password="$(cat "$SECRETS_DIR/pg-password")" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f "$ROOT_DIR/k8s/platform/postgres.yaml" >/dev/null
k -n db rollout status deploy/postgres --timeout=180s >/dev/null

for _ in $(seq 1 30); do
  k -n db exec deploy/postgres -- pg_isready -U vault -d demo >/dev/null 2>&1 && break
  sleep 2
done
k -n db exec deploy/postgres -- pg_isready -U vault -d demo >/dev/null || die "Postgres isn't accepting connections"
ok "postgres.db.svc ready"
