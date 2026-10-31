data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  # Who gets data access to the Service Bus from their machine: var.operator_object_ids, or else whoever runs `terraform apply`
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

# --- Service Bus: the queue and its dead-letter queue -----------------------------------------------

resource "azurerm_servicebus_namespace" "this" {
  name                = "sb-${var.name}-${random_string.suffix.result}" # globally unique: <name>.servicebus.windows.net
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard" # Basic has no duplicate detection, sessions, transactions or topics
  local_auth_enabled  = false      # Entra ID only: no SAS keys, no connection strings
  tags                = local.tags
}

# Every queue has a built-in dead-letter queue (<queue>/$deadletterqueue). Service Bus moves a message there after
# max_delivery_count failed attempts, or when it expires, and records the reason in the message's properties.
resource "azurerm_servicebus_queue" "orders" {
  name         = var.queue_name
  namespace_id = azurerm_servicebus_namespace.this.id

  max_delivery_count                      = 5      # attempts, then the dead-letter queue
  lock_duration                           = "PT1M" # a message is locked while processed; the Functions host renews the lock
  dead_lettering_on_message_expiration    = true   # an expired message goes to the dead-letter queue instead of vanishing
  requires_duplicate_detection            = true   # a message ID seen within the window is dropped (can't be changed later)
  duplicate_detection_history_time_window = "PT10M"
}

# --- Operators: send test messages and inspect the dead-letter queue from their machine ------------
# Owner/Contributor do not give access to messages: data-plane roles are separate.
# Once a pipeline runs Terraform, set var.operator_object_ids: otherwise the pipeline's own identity would grant
# itself this access and remove yours.
resource "azurerm_role_assignment" "operators" {
  for_each             = local.operators
  scope                = azurerm_servicebus_namespace.this.id
  role_definition_name = "Azure Service Bus Data Owner"
  principal_id         = each.value
}

# --- The Function's identity: Service Bus access with Entra ID, no key -----------------------------
resource "azurerm_user_assigned_identity" "consumer" {
  name                = "id-${var.name}-consumer"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# Processing messages only needs "Data Receiver" on the queue. But to scale the app out from zero, the Flex Consumption
# scale controller reads the queue length with this identity, which takes manage rights: "Data Owner".
# Scoped to this PoC's namespace, which holds nothing else.
resource "azurerm_role_assignment" "consumer" {
  scope                = azurerm_servicebus_namespace.this.id
  role_definition_name = "Azure Service Bus Data Owner"
  principal_id         = azurerm_user_assigned_identity.consumer.principal_id
  principal_type       = "ServicePrincipal" # avoids failures while the new identity replicates in Entra ID
}

# --- The Azure Function: Flex Consumption plan, scales to zero, billed per execution ----------------------

# Runtime storage of the Function App: host state and deployment packages, none of your messages. Shared keys stay
# enabled here because the azurerm Flex resource doesn't handle keyless runtime storage yet (provider issue 30732).
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

  # Service Bus: Entra ID with the consumer identity, no key
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.consumer.id]
  }

  # "ServiceBus" is the connection name in OrderFunction: its ServiceBus__* settings select Entra ID and the identity
  app_settings = {
    ServiceBus__fullyQualifiedNamespace = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
    ServiceBus__credential              = "managedidentity"
    ServiceBus__clientId                = azurerm_user_assigned_identity.consumer.client_id
    QUEUE_NAME                          = azurerm_servicebus_queue.orders.name

    # Java: the Application Insights Java agent sends the runs, their logs and their exceptions. Without it, an instance
    # started from a pre-warmed one (every scale-out) sends none of them, only CPU and memory counters.
    APPLICATIONINSIGHTS_ENABLE_AGENT = "true"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
  }
}

# --- Alerts: an email when messages are dead-lettered, pile up or keep failing --------------------------
# Metric alerts, evaluated by Azure Monitor. Stateful: one email when an alert fires, one when it resolves, none in
# between. Severity 1 = error (orders aren't processed), 2 = warning (someone must look). See README, "Monitoring".

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = substr(var.name, 0, 12) # shown in notifications, 12 characters max
  tags                = local.tags

  email_receiver {
    name                    = "operators"
    email_address           = var.alert_email
    use_common_alert_schema = true # the same email layout for every alert type
  }
}

# The dead-letter queue should stay empty: a message there is an order that failed 5 times, and needs a person
resource "azurerm_monitor_metric_alert" "dead_letters" {
  name                = "${var.name}-dead-letters"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_servicebus_namespace.this.id]
  description         = "Messages in ${azurerm_servicebus_queue.orders.name}/$deadletterqueue: triage them, then empty it (README, Monitoring)."
  severity            = 2
  frequency           = "PT1M" # checked every minute...
  window_size         = "PT5M" # ...over the last 5 minutes
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages" # messages in the dead-letter queue
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      name     = "EntityName" # the metric is per queue: this one
      operator = "Include"
      values   = [azurerm_servicebus_queue.orders.name]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }
}

# Falling behind: more than backlog_alert_threshold messages for 15 minutes straight. Messages being processed stay in
# the queue until completed and count too, so a busy queue is never empty: that's why the threshold isn't 0, and why it
# must stay above what the app processes at once at full scale (50 instances x 16 concurrent calls = 800).
resource "azurerm_monitor_metric_alert" "backlog" {
  name                = "${var.name}-backlog"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_servicebus_namespace.this.id]
  description         = "${azurerm_servicebus_queue.orders.name} has held more than ${var.backlog_alert_threshold} messages for 15 minutes: the function is falling behind or stopped (README, Monitoring)."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "ActiveMessages" # messages waiting or being processed
    aggregation      = "Minimum"        # lowest count over the 15 minutes: a burst drained in time doesn't fire it
    operator         = "GreaterThan"
    threshold        = var.backlog_alert_threshold

    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = [azurerm_servicebus_queue.orders.name]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }
}

# Failed runs are retried at once: many of them mean a dependency is down or a bad deployment, often before messages
# reach the dead-letter queue. Every attempt counts, so one message failing its 5 attempts alone doesn't fire it.
resource "azurerm_monitor_metric_alert" "failures" {
  name                = "${var.name}-failures"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_application_insights.this.id]
  description         = "More than 5 function runs failed within 15 minutes: the exceptions table of Application Insights says why (README, Finding the logs)."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed" # Application Insights records each function run as a request
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 5
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }
}
