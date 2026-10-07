# Everything lives in one Vault Enterprise namespace, as a tenant would.
resource "vault_namespace" "demo" {
  path = var.vault_namespace
}

locals {
  ns = vault_namespace.demo.path_fq
}

# ---------------------------------------------------------------------------
# KV v2 — static secret (scenario 2: rotation latency)
# ---------------------------------------------------------------------------
resource "vault_mount" "kv" {
  namespace = local.ns
  path      = "kv"
  type      = "kv"
  options   = { version = "2" }
}

resource "vault_kv_secret_v2" "app_config" {
  namespace = local.ns
  mount     = vault_mount.kv.path
  name      = "app/config"
  data_json = jsonencode({ message = "hello-from-vault" })

  # demo/rotate-kv.sh changes this value during the demo; don't fight it.
  lifecycle {
    ignore_changes = [data_json]
  }
}

# ---------------------------------------------------------------------------
# Database secrets engine — dynamic Postgres credentials (scenarios 1 and 5)
# ---------------------------------------------------------------------------
resource "vault_database_secrets_mount" "db" {
  namespace = local.ns
  path      = "database"

  postgresql {
    name              = "demo-postgres"
    connection_url    = "postgresql://{{username}}:{{password}}@postgres.db.svc.cluster.local:5432/demo?sslmode=disable"
    username          = "vault"
    password          = var.pg_password
    username_template = "v-{{.RoleName}}-{{random 8 | lowercase}}"
    allowed_roles     = ["app-vso", "app-eso"]
    verify_connection = true
  }
}

# One role per operator so their credentials are easy to tell apart in Vault and Postgres.
resource "vault_database_secret_backend_role" "app" {
  for_each = toset(["app-vso", "app-eso"])

  namespace = local.ns
  backend   = vault_database_secrets_mount.db.path
  name      = each.key
  db_name   = "demo-postgres"

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE demo TO \"{{name}}\";",
  ]
  revocation_statements = [
    "REVOKE CONNECT ON DATABASE demo FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";",
  ]

  default_ttl = var.db_default_ttl
  max_ttl     = var.db_max_ttl
}

# ---------------------------------------------------------------------------
# PKI — short-lived TLS certificates (scenario 4)
# ---------------------------------------------------------------------------
resource "vault_mount" "pki" {
  namespace             = local.ns
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000
}

resource "vault_pki_secret_backend_root_cert" "root" {
  namespace   = local.ns
  backend     = vault_mount.pki.path
  type        = "internal"
  common_name = "Demo Root CA"
  ttl         = "87600h"
  key_type    = "ec"
  key_bits    = 256
}

resource "vault_pki_secret_backend_role" "app" {
  namespace        = local.ns
  backend          = vault_mount.pki.path
  name             = "app"
  allowed_domains  = ["svc"]
  allow_subdomains = true
  key_type         = "ec"
  key_bits         = 256
  max_ttl          = var.pki_max_ttl

  depends_on = [vault_pki_secret_backend_root_cert.root]
}

# ---------------------------------------------------------------------------
# Transit — encrypts VSO's persisted client cache (scenario 5)
# ---------------------------------------------------------------------------
resource "vault_mount" "transit" {
  namespace = local.ns
  path      = "vso-transit"
  type      = "transit"
}

resource "vault_transit_secret_backend_key" "vso_cache" {
  namespace = local.ns
  backend   = vault_mount.transit.path
  name      = "vso-client-cache"
}

# ---------------------------------------------------------------------------
# Kubernetes auth — Vault runs in the cluster, so it uses its own service account
# (with system:auth-delegator) to review tokens.
# ---------------------------------------------------------------------------
resource "vault_auth_backend" "kubernetes" {
  namespace = local.ns
  type      = "kubernetes"
  path      = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "k8s" {
  namespace       = local.ns
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc.cluster.local"
}

resource "vault_kubernetes_auth_backend_role" "app_vso" {
  namespace                        = local.ns
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "app-vso"
  bound_service_account_names      = ["app"]
  bound_service_account_namespaces = ["app-vso"]
  audience                         = "vault"
  token_policies                   = [vault_policy.app_vso.name]
  token_ttl                        = 3600
}

resource "vault_kubernetes_auth_backend_role" "app_eso" {
  namespace                        = local.ns
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "app-eso"
  bound_service_account_names      = ["app"]
  bound_service_account_namespaces = ["app-eso"]
  audience                         = "vault"
  token_policies                   = [vault_policy.app_eso.name]
  token_ttl                        = 3600
}

resource "vault_kubernetes_auth_backend_role" "vso_operator" {
  namespace                        = local.ns
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "vso-operator"
  bound_service_account_names      = ["vault-secrets-operator-controller-manager"]
  bound_service_account_namespaces = ["vault-secrets-operator-system"]
  audience                         = "vault"
  token_policies                   = [vault_policy.vso_operator.name]
  token_ttl                        = 3600
}
