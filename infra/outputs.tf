output "queue_service_url" {
  description = "Queue endpoint of the storage account (QUEUE_SERVICE_URL)."
  value       = local.queue_service_url
}

output "queue_name" {
  description = "Main queue (QUEUE_NAME)."
  value       = azurerm_storage_queue.main.name
}

output "poison_queue_name" {
  description = "Poison queue (POISON_QUEUE_NAME)."
  value       = azurerm_storage_queue.poison.name
}

output "consumer_identity_client_id" {
  description = "Set as AZURE_CLIENT_ID on the consumer when it runs in Azure with the user-assigned identity."
  value       = azurerm_user_assigned_identity.consumer.client_id
}

output "env" {
  description = "The app's settings, plus the defaults of az storage commands. Usage: eval \"$(terraform output -raw env)\""
  value       = <<-EOT
    export QUEUE_SERVICE_URL=${local.queue_service_url}
    export QUEUE_NAME=${azurerm_storage_queue.main.name}
    export POISON_QUEUE_NAME=${azurerm_storage_queue.poison.name}
    export AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.this.name}
    export AZURE_STORAGE_AUTH_MODE=login
  EOT
}
