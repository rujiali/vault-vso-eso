#!/usr/bin/env bash
# One-screen health check: operators, sync status of every secret resource, app pods.
. "$(dirname "$0")/lib.sh"

log "Vault"
k -n vault exec vault-0 -- vault status 2>/dev/null | grep -E 'Sealed|Version|HA Mode' || warn "vault-0 not answering"

log "Operators"
k get pods -n vault-secrets-operator-system
k get pods -n external-secrets

log "VSO resources (app-vso)"
k -n app-vso get vaultstaticsecrets.secrets.hashicorp.com,vaultdynamicsecrets.secrets.hashicorp.com,vaultpkisecrets.secrets.hashicorp.com 2>/dev/null || true

log "ESO resources (app-eso)"
k -n app-eso get secretstore,externalsecret 2>/dev/null || true

log "Apps"
k get pods -A -l app=demo
