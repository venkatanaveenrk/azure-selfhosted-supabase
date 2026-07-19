# ================================================================
# VPN Gateway — Point-to-Site for Developer Access
# ================================================================
# Toggle the whole thing on/off via var.enable_vpn_gateway.
# Set to false later to save ~$143/mo when nobody's using it.
#
# Supports two auth methods simultaneously (var.vpn_auth_methods):
#   - AzureAD     -> users sign in with their Microsoft account + MFA
#   - Certificate -> classic client certificate (works on Linux too)
#
# SKU: VpnGw1AZ (the current zone-redundant family; the old VpnGw1
# retires Sept 2026).
# ================================================================

locals {
  vpn_use_azuread     = contains(var.vpn_auth_methods, "AzureAD")
  vpn_use_certificate = contains(var.vpn_auth_methods, "Certificate")

  # Azure AD's well-known VPN app ID (same for all tenants)
  azure_vpn_app_id = "41b23e61-6c1e-4545-b367-cd054e0ed4b4"
}

# ─── Public IP for the gateway (zone-redundant Standard) ───
resource "azurerm_public_ip" "vpn" {
  count               = var.enable_vpn_gateway ? 1 : 0
  name                = "${var.vm_name}-vpn-pip"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.region
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"] # zone-redundant — required for AZ SKUs
  tags                = local.common_tags
}

# ─── The VPN Gateway ───
resource "azurerm_virtual_network_gateway" "vpn" {
  count = var.enable_vpn_gateway ? 1 : 0

  name                = "${var.vm_name}-vpn-gw"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.region

  type     = "Vpn"
  vpn_type = "RouteBased"

  active_active = false
  enable_bgp    = false
  sku           = var.vpn_sku
  generation    = "Generation2"

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn[0].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  # ─── Point-to-site configuration ───
  vpn_client_configuration {
    address_space = var.vpn_client_address_pool

    # Protocols — OpenVPN supports both auth types and works cross-platform.
    # IkeV2 is added for native Windows VPN client compatibility.
    vpn_client_protocols = ["OpenVPN", "IkeV2"]

    # ── Azure AD authentication (only when enabled) ──
    aad_tenant   = local.vpn_use_azuread && var.vpn_azure_ad_tenant_id != "" ? "https://login.microsoftonline.com/${var.vpn_azure_ad_tenant_id}" : null
    aad_audience = local.vpn_use_azuread && var.vpn_azure_ad_tenant_id != "" ? local.azure_vpn_app_id : null
    aad_issuer   = local.vpn_use_azuread && var.vpn_azure_ad_tenant_id != "" ? "https://sts.windows.net/${var.vpn_azure_ad_tenant_id}/" : null

    # ── Certificate authentication (only when enabled) ──
    dynamic "root_certificate" {
      for_each = local.vpn_use_certificate && var.vpn_root_certificate_data != "" ? [1] : []
      content {
        name             = "p2s-root-cert"
        public_cert_data = var.vpn_root_certificate_data
      }
    }
  }

  tags                = local.common_tags

  lifecycle {
    # VPN Gateways take 30-45 min to delete; protect against accidental destroy
    prevent_destroy = false # set true once stable; keep false during setup
  }
}
