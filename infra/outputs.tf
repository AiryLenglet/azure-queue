output "servicebus_namespace" {
  description = "Service Bus namespace: <name>.servicebus.windows.net."
  value       = azurerm_servicebus_namespace.this.name
}

output "queue_name" {
  description = "Service Bus queue the function consumes. Its dead-letter queue is <queue>/$deadletterqueue."
  value       = azurerm_servicebus_queue.orders.name
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
    export SERVICEBUS_NAMESPACE=${azurerm_servicebus_namespace.this.name}
    export QUEUE_NAME=${azurerm_servicebus_queue.orders.name}
  EOT
}
