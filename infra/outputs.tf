output "queue_name" {
  description = "Main queue."
  value       = azurerm_storage_queue.main.name
}

output "poison_queue_name" {
  description = "Poison queue."
  value       = azurerm_storage_queue.poison.name
}

output "function_app_name" {
  description = "Function App the code is deployed to (see README)."
  value       = azurerm_function_app_flex_consumption.this.name
}

output "env" {
  description = "Variables used by the README commands. Usage: eval \"$(terraform output -raw env)\""
  value       = <<-EOT
    export RESOURCE_GROUP=${azurerm_resource_group.this.name}
    export FUNCTION_APP=${azurerm_function_app_flex_consumption.this.name}
    export APP_INSIGHTS=${azurerm_application_insights.this.name}
    export QUEUE_NAME=${azurerm_storage_queue.main.name}
    export POISON_QUEUE_NAME=${azurerm_storage_queue.poison.name}
    export AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.this.name}
    export AZURE_STORAGE_AUTH_MODE=login
  EOT
}
