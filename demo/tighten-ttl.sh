#!/usr/bin/env bash
# "With Reloader" variant of scenarios 4 and 5: the Vault team shortens credential and
# certificate lifetimes. Applied to BOTH operators, so it's a fair test.
#
#   Database: default_ttl 10m -> 2m on both roles. ESO still refreshes every 5m.
#   TLS:      PKI role max_ttl 15m -> 90s. Both operators ask for 5m certificates and Vault
#             caps them at 90s. ESO still refreshes every 3m.
#
#   VSO schedules from what Vault actually returned (renew at 67% of the lease; new cert
#   30s before the certificate's real expiry), so its app stays valid.
#   ESO refreshes on its own fixed interval, so each credential or certificate expires before
#   the next one arrives. Even with Reloader, the ESO app runs on an expired credential and
#   serves an expired certificate for part of every cycle.
#
#   demo/tighten-ttl.sh          tighten
#   demo/tighten-ttl.sh reset    back to the Terraform values (DB 10m, PKI max 15m)
. "$(dirname "$0")/../scripts/lib.sh"

if [ "${1:-}" = "reset" ]; then db_ttl=10m; pki_max=15m; else db_ttl=2m; pki_max=90s; fi

log "Database credentials: default_ttl $db_ttl on both roles"
for role in app-vso app-eso; do
  v write "database/roles/$role" default_ttl="$db_ttl" >/dev/null
  ok "database/roles/$role  default_ttl=$(v read -field=default_ttl "database/roles/$role")s"
done

log "TLS certificates: PKI role max_ttl $pki_max (applies to both operators)"
v patch pki/roles/app max_ttl="$pki_max" >/dev/null
v read -field=allowed_domains pki/roles/app | grep -q svc \
  || die "pki/roles/app lost its settings. Restore it with: (cd terraform && terraform apply)"
ok "pki/roles/app  max_ttl=$(v read -field=max_ttl pki/roles/app)s"

# Make ESO fetch now, so the new lifetimes show up without waiting for its next poll.
for es in db-creds app-tls; do
  k -n app-eso annotate externalsecret "$es" force-sync="$(date +%s)" --overwrite >/dev/null
done
ok "ESO asked to refresh db-creds and app-tls now"

if [ "${1:-}" = "reset" ]; then
  ok "Reset. New credentials last 10 minutes and certificates 5 minutes again."
else
  cat <<'EOF'

    Database (row 2): ESO refreshes every 5m, each credential lasts 2m.
      ESO goes red ~2m from now ("app can't log in"), green at the next refresh, red again.
    TLS (row 3): ESO refreshes every 3m, each certificate lasts 90s.
      ESO goes red ~90s from now ("app serving an expired cert") for 90s in every 3 minutes.
    VSO stays green on both rows.
    Put it back afterwards: demo/tighten-ttl.sh reset
EOF
fi
