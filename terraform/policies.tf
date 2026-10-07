# Least-privilege policies. The two app policies are deliberately near-identical so the
# comparison is about the operators, not about who has more access. The only extra on the VSO
# side is "subscribe", which is what lets VSO receive Vault events for instant updates.

resource "vault_policy" "app_vso" {
  namespace = local.ns
  name      = "app-vso"
  policy    = <<-EOT
    # KV: read + subscribe to change events (VSO instant updates).
    # Matches HashiCorp's documented policy for instant updates (the secret path itself),
    # plus the kv-v2 API paths.
    path "kv/app/*" {
      capabilities          = ["read", "list", "subscribe"]
      subscribe_event_types = ["*"]
    }
    path "kv/data/app/*" {
      capabilities          = ["read", "list", "subscribe"]
      subscribe_event_types = ["*"]
    }
    path "kv/metadata/app/*" {
      capabilities          = ["read", "list", "subscribe"]
      subscribe_event_types = ["*"]
    }
    path "sys/events/subscribe/kv*" {
      capabilities = ["read"]
    }

    # Dynamic database credentials
    path "database/creds/app-vso" {
      capabilities = ["read"]
    }

    # PKI issue + revoke
    path "pki/issue/app" {
      capabilities = ["create", "update"]
    }
    path "pki/revoke" {
      capabilities = ["create", "update"]
    }

    # Revoke its own leases when a VaultDynamicSecret is deleted (renew is in the default policy)
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
  EOT
}

resource "vault_policy" "app_eso" {
  namespace = local.ns
  name      = "app-eso"
  policy    = <<-EOT
    path "kv/data/app/*" {
      capabilities = ["read", "list"]
    }
    path "kv/metadata/app/*" {
      capabilities = ["read", "list"]
    }

    path "database/creds/app-eso" {
      capabilities = ["read"]
    }

    path "pki/issue/app" {
      capabilities = ["create", "update"]
    }
    path "pki/revoke" {
      capabilities = ["create", "update"]
    }

    # Same lease rights as VSO — if ESO doesn't revoke, it's not for lack of permission.
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
  EOT
}

resource "vault_policy" "vso_operator" {
  namespace = local.ns
  name      = "vso-operator"
  policy    = <<-EOT
    # Encrypt/decrypt VSO's persisted client cache
    path "vso-transit/encrypt/vso-client-cache" {
      capabilities = ["create", "update"]
    }
    path "vso-transit/decrypt/vso-client-cache" {
      capabilities = ["create", "update"]
    }
  EOT
}
