# ================================================================
# Network — NEW VNet for Supabase + App Services
# ================================================================
# Creates:
#   - New VNet (10.50.0.0/16) in supabase-rg
#   - GatewaySubnet       (10.50.0.0/27)   — VPN Gateway lives here
#   - snet-supabase       (10.50.10.0/24)  — the Supabase VM
#   - snet-appservice     (10.50.20.0/24)  — delegated to Microsoft.Web/serverFarms
#   - NSG on snet-supabase — denies internet, allows VirtualNetwork
# ================================================================

data "azurerm_resource_group" "rg" {
  name = var.resource_group
}

# ─── The VNet ───
resource "azurerm_virtual_network" "supabase" {
  name                = var.vnet_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.region
  address_space       = [var.vnet_address_space]
  tags                = local.common_tags
}

# ─── GatewaySubnet — required exact name for VPN Gateway ───
# Azure recognises subnets by the literal name "GatewaySubnet"; renaming breaks the gateway.
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.supabase.name
  address_prefixes     = [var.subnet_gateway_cidr]
}

# ─── snet-supabase — the VM's subnet ───
resource "azurerm_subnet" "supabase" {
  name                 = "snet-supabase"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.supabase.name
  address_prefixes     = [var.subnet_supabase_cidr]
}

# ─── snet-appservice — delegated for App Service VNet integration ───
# App Service injects NICs here when an app enables VNet integration.
resource "azurerm_subnet" "appservice" {
  name                 = "snet-appservice"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.supabase.name
  address_prefixes     = [var.subnet_appservice_cidr]

  delegation {
    name = "appservice-delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

# ─── NSG for the Supabase VM subnet ───
# Default Azure rules already deny all internet inbound. We add EXPLICIT rules
# so the intent is auditable: allow only VirtualNetwork sources on 22/8000/3000.
resource "azurerm_network_security_group" "supabase" {
  name                = "${var.vm_name}-nsg"
  location            = var.region
  resource_group_name = data.azurerm_resource_group.rg.name
  tags                = local.common_tags

  # SSH — only from within the VNet (VPN clients route through it)
  security_rule {
    name                       = "allow-ssh-from-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # Kong gateway — from VNet (App Services + VPN clients)
  security_rule {
    name                       = "allow-kong-from-vnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8000"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # Studio dashboard — from VNet (mainly via VPN port-forward)
  security_rule {
    name                       = "allow-studio-from-vnet"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # Explicit deny — all internet inbound (defense in depth, Azure also denies by default)
  security_rule {
    name                       = "deny-all-internet"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# Bind NSG to the Supabase subnet
resource "azurerm_subnet_network_security_group_association" "supabase" {
  subnet_id                 = azurerm_subnet.supabase.id
  network_security_group_id = azurerm_network_security_group.supabase.id
}

# ─── NIC for the VM — private IP only, no public IP ───
resource "azurerm_network_interface" "supabase" {
  name                = "${var.vm_name}-nic"
  location            = var.region
  resource_group_name = data.azurerm_resource_group.rg.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.supabase.id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id — intentionally private
  }
}
