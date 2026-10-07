terraform {
  required_version = ">= 1.5"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = ">= 4.4"
    }
  }
}

provider "vault" {
  address = var.vault_addr
  token   = var.vault_token # root token from init — lab only
}
