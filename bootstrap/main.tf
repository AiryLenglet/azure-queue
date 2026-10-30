# Run once per subscription. Creates the storage holding every Terraform state: the other stacks' (infra/, ...)
# and its own. It can't live in infra/: the states must survive a `terraform destroy` of the infra.

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  tags = {
    purpose    = "terraform-state"
    managed_by = "terraform"
  }
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-tfstate"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                     = "sttfstate${random_string.suffix.result}" # globally unique
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS" # GZRS in production: the state is the map of your whole infrastructure
  tags                     = local.tags

  # Same baseline as the app: Entra ID only, no keys
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true # every write keeps the previous state version: a broken state can be restored

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  # Holds every Terraform state, its own included: Terraform refuses any plan that would delete or replace it.
  # To remove it for good, see "Clean up" in the README.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name               = "tfstate"
  storage_account_id = azurerm_storage_account.tfstate.id

  lifecycle {
    prevent_destroy = true # same reason as the storage account
  }
}

# Read and write the state blobs. Owner on the subscription is not enough: blob data access is a separate role.
resource "azurerm_role_assignment" "me_tfstate" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
