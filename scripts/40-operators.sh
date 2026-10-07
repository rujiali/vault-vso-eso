#!/usr/bin/env bash
# Installs both operators. VSO goes in after Terraform because its encrypted client cache
# needs the transit key and the vso-operator auth role to exist.
. "$(dirname "$0")/lib.sh"

log "Vault Secrets Operator $VSO_CHART_VERSION"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update hashicorp external-secrets >/dev/null

if [ "$VAULT_NS" != "demo" ]; then
  warn "helm/vso-values.yaml has namespace: demo — overriding to $VAULT_NS"
fi
h upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator-system --create-namespace \
  --version "$VSO_CHART_VERSION" \
  -f "$ROOT_DIR/helm/vso-values.yaml" \
  --set controller.manager.clientCache.storageEncryption.namespace="$VAULT_NS" \
  --wait --timeout 5m >/dev/null
ok "VSO installed"

log "External Secrets Operator ${ESO_CHART_VERSION:-(latest)}"
# shellcheck disable=SC2086
h upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  ${ESO_CHART_VERSION:+--version "$ESO_CHART_VERSION"} \
  -f "$ROOT_DIR/helm/eso-values.yaml" \
  --wait --timeout 5m >/dev/null
k wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=60s >/dev/null
ok "ESO installed"

h list -A | grep -E 'NAME|vault-secrets-operator|external-secrets'
