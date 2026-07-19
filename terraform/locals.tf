# ================================================================
# Locals — Computed Values
# ================================================================
# Centralizes the customer tag so every resource in this module is
# labeled consistently, without editing var.tags' default per deploy.
# ================================================================

locals {
  # Merge the customer identity into whatever tags were passed in.
  # Any resource that does `tags = var.tags` should switch to
  # `tags = local.common_tags` to pick this up.
  common_tags = merge(
    var.tags,
    {
      customer = var.customer_name
    }
  )
}
