variable "vault_addr" {
  type    = string
  default = "http://127.0.0.1:8200"
}

variable "vault_token" {
  type      = string
  sensitive = true
}

variable "vault_namespace" {
  type    = string
  default = "demo"
}

variable "pg_password" {
  type      = string
  sensitive = true
}

# Database credential lifetimes. VSO renews at 67% of the TTL and rotates when max_ttl is reached.
variable "db_default_ttl" {
  type    = number
  default = 600 # 10 minutes
}

variable "db_max_ttl" {
  type    = number
  default = 1800 # 30 minutes
}

# Short certificate lifetimes so renewal happens during the demo.
variable "pki_max_ttl" {
  type    = number
  default = 900 # 15 minutes
}
