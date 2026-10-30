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

# --- The Function's identity: queue access with Entra ID, least privilege, per queue ---------------
resource "azurerm_user_assigned_identity" "consumer" {
  name                = "id-${var.name}-consumer"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# What the queue trigger needs on the main queue, nothing else: Microsoft documents "Storage Queue Data Reader" and
# "Message Processor" for the trigger, and the host also updates messages (lease renewal, retry delay).
# No built-in role is that narrow: "Data Contributor" can also change or delete the queue itself.
resource "azurerm_role_definition" "queue_consumer" {
  name        = "Queue consumer (${azurerm_storage_account.this.name})" # custom role names are unique per tenant
  scope       = azurerm_resource_group.this.id
  description = "Read a queue; receive, peek, delete and update its messages. Nothing else."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/queueServices/queues/read", # the queue itself, as in Storage Queue Data Reader
    ]
    data_actions = [
      "Microsoft.Storage/storageAccounts/queueServices/queues/messages/read",           # peek
      "Microsoft.Storage/storageAccounts/queueServices/queues/messages/process/action", # receive, delete
      "Microsoft.Storage/storageAccounts/queueServices/queues/messages/write",          # update: lease renewal while running, retry delay
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

# The host moves failed messages here and the output binding writes the non-retryable ones. Both may create the queue
# if it's missing, which "Message Sender" can't do: Microsoft documents Contributor for queue outputs. Scoped to this queue.
resource "azurerm_role_assignment" "consumer_poison" {
  scope                = "${local.queues_scope}/${azurerm_storage_queue.poison.name}"
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.consumer.principal_id
  principal_type       = "ServicePrincipal"
}

# --- The Azure Function: Flex Consumption plan, scales to zero, billed per execution ----------------------

# Runtime storage of the Function App: host state and deployment packages, none of your messages. Shared keys stay
# enabled here because the azurerm Flex resource doesn't handle keyless runtime storage yet (provider issue 30732).
# Your messages stay in the keyless account above.
resource "azurerm_storage_account" "functions" {
  name                     = "st${var.name}fn${random_string.suffix.result}" # globally unique
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.tags

  shared_access_key_enabled       = true # used by the Functions runtime (host storage, deployments)
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "deployments" {
  name               = "deployments"
  storage_account_id = azurerm_storage_account.functions.id
}

# Logs: a Flex Consumption app reports through Application Insights
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "java"
  tags                = local.tags
}

resource "azurerm_service_plan" "functions" {
  name                = "asp-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  sku_name            = "FC1" # Flex Consumption
  tags                = local.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = "func-${var.name}-${random_string.suffix.result}" # globally unique: <name>.azurewebsites.net
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.functions.id
  tags                = local.tags

  runtime_name           = "java"
  runtime_version        = "21"
  instance_memory_in_mb  = 2048
  maximum_instance_count = 50 # caps scale-out, and so the cost

  # Runtime storage, with a key (see azurerm_storage_account.functions)
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.deployments.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.functions.primary_access_key

  # The queues: Entra ID with the consumer identity, no key
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.consumer.id]
  }

  app_settings = {
    QueueStorage__queueServiceUri = local.queue_service_url # "QueueStorage" is the connection name in OrderFunction
    QueueStorage__credential      = "managedidentity"
    QueueStorage__clientId        = azurerm_user_assigned_identity.consumer.client_id
    QUEUE_NAME                    = azurerm_storage_queue.main.name
    POISON_QUEUE_NAME             = azurerm_storage_queue.poison.name
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
  }
}
