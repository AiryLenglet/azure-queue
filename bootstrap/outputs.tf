output "backend_config" {
  description = "Partial backend configuration for every stack, this one included. From bootstrap/: terraform output -raw backend_config > backend.hcl, then copy it to infra/."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
  EOT
}
