data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  queue_service_url = trimsuffix(azurerm_storage_account.this.primary_queue_endpoint, "/")
  queues_scope      = "${azurerm_storage_account.this.id}/queueServices/default/queues"

  # Who gets data access to the queues from their machine: var.operator_object_ids, or else whoever runs `terraform apply`
  operators = toset(coalescelist(var.operator_object_ids, [data.azurerm_client_config.current.object_id]))

  # Set on every resource that supports tags (cost reports, ownership, policy)
  tags = {
    project    = var.name
    managed_by = "terraform"
  }
}

# The PoC's resource group shares its lifecycle: one `terraform destroy` removes everything.
# If a platform team provides the resource group, replace this with: data "azurerm_resource_group" "this" { name = "..." }
resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "this" {
  name                     = "st${var.name}${random_string.suffix.result}" # globally unique
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  tags                     = local.tags

  # Entra ID (RBAC) only: no account keys, no SAS, no connection strings to leak
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_queue" "main" {
  name               = var.queue_name
  storage_account_id = azurerm_storage_account.this.id
}

# Storage queues have no built-in dead-letter queue: the consumer moves failed messages here.
# "<queue>-poison" is the convention used by Azure Functions.
resource "azurerm_storage_queue" "poison" {
  name               = "${var.queue_name}-poison"
  storage_account_id = azurerm_storage_account.this.id
}

# --- Operators: run the producer, consumer and tools from their machine after `az login` ----------
# Owner/Contributor do not give access to messages: data-plane roles are separate.
# Once a pipeline runs Terraform, set var.operator_object_ids: otherwise the pipeline's own identity would grant
# itself this access and remove yours.
resource "azurerm_role_assignment" "operators" {
  for_each             = local.operators
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = each.value
}

# --- The consumer once deployed in Azure (Container Apps, AKS, VM...): least privilege, per queue ---
resource "azurerm_user_assigned_identity" "consumer" {
  name                = "id-${var.name}-consumer"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# receive + delete + updateMessage (retry backoff), nothing else. No built-in role is that narrow:
# "Message Processor" cannot update a message, "Data Contributor" can also change or delete the queue itself.
resource "azurerm_role_definition" "queue_consumer" {
  name        = "Queue consumer (${azurerm_storage_account.this.name})" # custom role names are unique per tenant
  scope       = azurerm_resource_group.this.id
  description = "Receive, delete and update queue messages. Nothing else."

  permissions {
    data_actions = [
      "Microsoft.Storage/storageAccounts/queueServices/queues/messages/process/action", # receive, delete
      "Microsoft.Storage/storageAccounts/queueServices/queues/messages/write",          # update (retry backoff)
    ]
  }

  assignable_scopes = [azurerm_resource_group.this.id]
}

resource "azurerm_role_assignment" "consumer_main" {
  scope              = "${local.queues_scope}/${azurerm_storage_queue.main.name}"
  role_definition_id = azurerm_role_definition.queue_consumer.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.consumer.principal_id
  principal_type     = "ServicePrincipal" # avoids failures while the new identity replicates in Entra ID
}

# send only
resource "azurerm_role_assignment" "consumer_poison" {
  scope                = "${local.queues_scope}/${azurerm_storage_queue.poison.name}"
  role_definition_name = "Storage Queue Data Message Sender"
  principal_id         = azurerm_user_assigned_identity.consumer.principal_id
  principal_type       = "ServicePrincipal"
}
