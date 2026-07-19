# ================================================================
# Virtual Machine — Supabase Host
# ================================================================
# Ubuntu 24.04 LTS, Trusted Launch (secure boot + vTPM), system-
# assigned managed identity, SSH-key auth (no passwords).
#
# Data persistence: SEPARATE managed disk (prevent_destroy) — Postgres
# data + Storage files live there, surviving any container/VM event.
# ================================================================

# ─── Admin SSH keypair (Terraform-managed "break-glass" key) ───
resource "tls_private_key" "vm_admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ─── Existing Key Vault (for storing keys + VM-side secret reads) ───
data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group
}

data "azurerm_client_config" "current" {}

# ─── Data disk — the persistence guarantee ───
resource "azurerm_managed_disk" "supabase_data" {
  name                 = "${var.vm_name}-data-disk"
  location             = var.region
  resource_group_name  = data.azurerm_resource_group.rg.name
  storage_account_type = var.data_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  zone                 = var.vm_zone
  tags                = local.common_tags

  lifecycle {
    # Never let an accidental destroy take the data.
    prevent_destroy = true
  }
}

# ─── The VM ───
resource "azurerm_linux_virtual_machine" "supabase" {
  name                = var.vm_name
  location            = var.region
  resource_group_name = data.azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = var.admin_username
  zone                = var.vm_zone
  tags                = local.common_tags

  # Critical: disable password auth on the VM itself (defense in depth)
  disable_password_authentication = true

  network_interface_ids = [azurerm_network_interface.supabase.id]

  # ─── Trusted Launch ───
  secure_boot_enabled = true
  vtpm_enabled        = true

  # ─── System-assigned managed identity ───
  # VM gets an Azure AD identity. Deploy/backup scripts authenticate to
  # Key Vault as this identity — no stored credentials.
  identity {
    type = "SystemAssigned"
  }

  # ─── SSH keys ───
  # The admin (break-glass) key
  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.vm_admin.public_key_openssh
  }

  # Per-developer keys (optional). Each one is added as a parallel
  # admin_ssh_key block. To revoke a dev: remove from the map, apply.
  dynamic "admin_ssh_key" {
    for_each = var.developer_ssh_public_keys
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  # ─── OS disk ───
  os_disk {
    name                 = "${var.vm_name}-os-disk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  # ─── Ubuntu 24.04 LTS Gen2 ───
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # ─── Cloud-init: Docker, disk mount, systemd autostart ───
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    data_disk_lun  = 0
    admin_username = var.admin_username
  }))

  boot_diagnostics {} # managed storage account, free

  lifecycle {
    # cloud-init runs once at first boot; ignore later drift on it
    ignore_changes = [custom_data]
  }
}

# ─── Attach the data disk ───
resource "azurerm_virtual_machine_data_disk_attachment" "supabase_data" {
  managed_disk_id    = azurerm_managed_disk.supabase_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.supabase.id
  lun                = 0
  caching            = "ReadWrite"
}

# ─── Key Vault role: VM's managed identity reads secrets ───
# This is what lets `az keyvault secret show --auth-type identity`
# work on the VM with no stored credentials.
resource "azurerm_role_assignment" "vm_kv_secrets_user" {
  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.supabase.identity[0].principal_id
}

# Some Key Vaults are configured with access policies rather than RBAC.
# This access_policy is a belt-and-braces fallback; harmless if RBAC mode.
resource "azurerm_key_vault_access_policy" "vm_secrets" {
  key_vault_id = data.azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_virtual_machine.supabase.identity[0].principal_id

  secret_permissions = ["Get", "List"]
}

# ─── Store the admin SSH private key in Key Vault ───
# Only retrieve this in a true break-glass scenario; per-dev keys (above)
# are the normal access path.
resource "azurerm_key_vault_secret" "vm_admin_ssh_key" {
  name         = "SUPABASE-VM-ADMIN-SSH-KEY"
  value        = tls_private_key.vm_admin.private_key_pem
  key_vault_id = data.azurerm_key_vault.kv.id
  content_type = "supabase vm admin ssh private key (break-glass)"
  tags                = local.common_tags
}
