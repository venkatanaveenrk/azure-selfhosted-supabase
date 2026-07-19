# ================================================================
# Terraform + Provider versions
# ================================================================
# Backend config supplied at runtime via -backend-config flags (see
# DEPLOY.md Step 5) so the same module works across multiple client
# deployments — only the state-file key differs per deployment.
# ================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.95"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {
    virtual_machine {
      # Don't let a destroy leave orphaned disks
      delete_os_disk_on_deletion = true
    }
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}
