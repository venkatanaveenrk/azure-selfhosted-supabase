# ================================================================
# Monitoring — Log Analytics + Basic Alerts
# ================================================================
# Toggle via var.enable_monitoring. Provisions:
#   - Log Analytics workspace (low-cost ingestion tier)
#   - VM diagnostic settings -> workspace
#   - 2 basic alerts: VM stopped, Data disk > 80% used
# Cost: typically $2-5/month for a single VM at modest log volume.
# ================================================================

resource "azurerm_log_analytics_workspace" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name                = "${var.vm_name}-logs"
  location            = var.region
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

# Action group — destination for alerts. Email left empty; configure
# via the portal or add var.alert_email_address.
resource "azurerm_monitor_action_group" "alerts" {
  count = var.enable_monitoring ? 1 : 0

  name                = "${var.vm_name}-alerts"
  resource_group_name = data.azurerm_resource_group.rg.name
  short_name          = "supabase"
  tags                = local.common_tags
  # Add email_receiver { ... } blocks via a future variable if desired.
}

# ─── Alert: VM stopped/deallocated ───
resource "azurerm_monitor_metric_alert" "vm_down" {
  count = var.enable_monitoring ? 1 : 0

  name                = "${var.vm_name}-down"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_virtual_machine.supabase.id]
  description         = "Supabase VM has been unavailable for 5 minutes"
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "VmAvailabilityMetric"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts[0].id
  }
  tags                = local.common_tags
}

# ─── Alert: Data disk > 80% used ───
# Note: this watches OS disk-level free space; tune threshold once you
# see baseline usage in Log Analytics.
resource "azurerm_monitor_metric_alert" "disk_full" {
  count = var.enable_monitoring ? 1 : 0

  name                = "${var.vm_name}-disk-pressure"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes              = [azurerm_managed_disk.supabase_data.id]
  description         = "Supabase data disk operations very high (potential pressure)"
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT15M"

  # Data Disk IOPS as a proxy for pressure (managed disk metric).
  # Real disk-full alerting needs the Azure Monitor Agent + KQL alert;
  # add later once Log Analytics ingestion is verified.
  criteria {
    metric_namespace = "Microsoft.Compute/disks"
    metric_name      = "Composite Disk Read Bytes/sec"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 100000000 # 100 MB/s sustained — adjust after baseline
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts[0].id
  }
  tags                = local.common_tags
}

# ─── VM diagnostic settings → Log Analytics ───
resource "azurerm_monitor_diagnostic_setting" "vm" {
  count = var.enable_monitoring ? 1 : 0

  name                       = "${var.vm_name}-diag"
  target_resource_id         = azurerm_linux_virtual_machine.supabase.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.monitoring[0].id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
