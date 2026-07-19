# ================================================================
# Variables — Supabase VM Infrastructure (v3)
# ================================================================
# Reusable across any client/project — set var.customer_name and the
# handful of naming variables below per deployment. Nothing in this
# module is hardcoded to a specific company or product.
#
# Defaults reflect the production-validated configuration:
#   - VPN gateway OFF (App Service VNet integration is the access model)
#   - App Service subnet /22 (Microsoft.Web delegation minimum)
#   - Monitoring OFF (opt-in)
# Change only what you mean to change.
#
# >>> ACTION REQUIRED before terraform apply <<<
#   1. Set var.customer_name (used for tagging + Studio branding)
#   2. Set var.admin_username (Azure reserves common names like "admin")
#   3. (Optional) Add SSH keys to var.developer_ssh_public_keys
#   4. (Optional) Enable VPN by flipping var.enable_vpn_gateway = true
#
# Deploying for multiple clients? Run this module once per client with
# a different customer_name, resource_group, key_vault_name, vm_name,
# and non-overlapping vnet_address_space. See DEPLOY.md.
# ================================================================

# ─── Client / project identity ───
variable "customer_name" {
  description = "Client or project name. Used in resource tags and Studio branding — does not need to match any Azure resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9 ._-]{2,64}$", var.customer_name))
    error_message = "customer_name must be 2-64 characters: letters, numbers, spaces, dots, hyphens, underscores."
  }
}

# ─── Existing / reused resources ───
variable "resource_group" {
  description = "Resource group (reused — must already exist). Suggested pattern: <customer>-supabase-rg"
  type        = string
  default     = "supabase-rg"
}

variable "region" {
  description = "Azure region"
  type        = string
  default     = "northeurope"
}

variable "key_vault_name" {
  description = "Existing Key Vault — secrets are written here + VM reads from here"
  type        = string
  default     = "supabase-kv"
}

# ─── New VNet (created by this stack) ───
variable "vnet_name" {
  description = "Name of the NEW VNet this stack creates"
  type        = string
  default     = "supabase-vnet"
}

variable "vnet_address_space" {
  description = "VNet address space (CIDR)"
  type        = string
  default     = "10.50.0.0/16"
}

# Subnet CIDRs — all carved from the VNet's address space above
variable "subnet_gateway_cidr" {
  description = "GatewaySubnet — required exact name for VPN Gateway. /27 minimum."
  type        = string
  default     = "10.50.0.0/27"
}

variable "subnet_supabase_cidr" {
  description = "Subnet for the Supabase VM"
  type        = string
  default     = "10.50.10.0/24"
}

variable "subnet_appservice_cidr" {
  description = <<EOT
    Subnet delegated to App Service for VNet integration.
    MUST be /26 or larger; we default to /22 for headroom across many apps.
    Microsoft.Web delegation requires a non-tiny block (the regional VNet
    integration injects multiple NICs per app).
  EOT
  type        = string
  default     = "10.50.32.0/22"
}

variable "vpn_client_address_pool" {
  description = "Address pool assigned to VPN clients when connected. MUST NOT overlap the VNet."
  type        = list(string)
  default     = ["172.16.50.0/24"]
}

# ─── VM configuration ───
variable "vm_name" {
  description = "Name of the Supabase VM"
  type        = string
  default     = "supabase-vm"
}

variable "vm_size" {
  description = "VM size. Start small; resize later by editing this and re-applying."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "admin_username" {
  description = "Linux admin username for the VM. >>> FILL IN your chosen username <<<"
  type        = string
  default     = "REPLACE_WITH_YOUR_USERNAME"

  validation {
    condition     = !contains(["admin", "administrator", "root", "user", "test", "guest", "console", "1"], lower(var.admin_username))
    error_message = "Username is in Azure's reserved list. Pick something else."
  }
}

variable "vm_zone" {
  description = "Availability zone (1, 2, or 3)"
  type        = string
  default     = "1"
}

variable "developer_ssh_public_keys" {
  description = "Map of developer name -> their SSH public key. Their PUBLIC key only. Leave empty to start; add later for direct SSH access."
  type        = map(string)
  default     = {}
  # Example:
  # default = {
  #   "naveen" = "ssh-ed25519 AAAAC3... naveen@laptop"
  #   "alice"  = "ssh-rsa AAAAB3...    alice@laptop"
  # }
}

# ─── Data disk (the data-safety foundation) ───
variable "data_disk_size_gb" {
  description = "Size of the managed data disk (Postgres + Storage files + Docker root)"
  type        = number
  default     = 128
}

variable "data_disk_type" {
  description = "Managed disk SKU. Premium_LRS recommended for database workloads."
  type        = string
  default     = "Premium_LRS"
}

# ─── VPN Gateway (OFF by default — opt-in) ───
variable "enable_vpn_gateway" {
  description = <<EOT
    Toggle the VPN Gateway on/off.
    Default OFF saves ~$365/mo. Recommended only when dev teams need direct
    access to the VM/Studio from outside Azure. For app-tier access, use
    App Service VNet integration instead (no VPN needed).
  EOT
  type        = bool
  default     = false
}

variable "vpn_sku" {
  description = <<EOT
    VPN Gateway SKU.
    Use VpnGw2AZ — VpnGw1AZ was deprecated and rejects new provisions.
    Costs about $365/mo when enabled.
  EOT
  type        = string
  default     = "VpnGw2AZ"

  validation {
    condition     = contains(["VpnGw2AZ", "VpnGw3AZ", "VpnGw4AZ", "VpnGw5AZ"], var.vpn_sku)
    error_message = "Pick a non-deprecated AZ SKU. VpnGw1AZ is no longer accepted by Azure."
  }
}

variable "vpn_auth_methods" {
  description = "Which P2S auth methods to enable. Both = belt-and-braces flexibility."
  type        = list(string)
  default     = ["AzureAD", "Certificate"]

  validation {
    condition     = alltrue([for m in var.vpn_auth_methods : contains(["AzureAD", "Certificate"], m)])
    error_message = "Each method must be 'AzureAD' or 'Certificate'."
  }
}

variable "vpn_azure_ad_tenant_id" {
  description = "Azure AD tenant ID for VPN auth (only used if 'AzureAD' is in vpn_auth_methods). Find: az account show --query tenantId"
  type        = string
  default     = ""
}

variable "vpn_root_certificate_data" {
  description = "Base64 root certificate (.cer) public key, no PEM headers, no newlines. Only used if 'Certificate' is in vpn_auth_methods."
  type        = string
  default     = ""
  sensitive   = true
}

# ─── Monitoring (OFF by default — opt-in) ───
variable "enable_monitoring" {
  description = "Provision Log Analytics workspace + basic alerts (~$2-5/mo). Opt-in."
  type        = bool
  default     = false
}

# ─── Tagging ───
# Note: default maps in Terraform can't reference other variables, so
# customer_name is merged into these tags via a local in versions.tf's
# companion locals.tf, not hardcoded here.
variable "tags" {
  description = "Additional tags applied to all resources (merged with the customer tag)"
  type        = map(string)
  default = {
    managed_by = "terraform"
    component  = "supabase"
  }
}
