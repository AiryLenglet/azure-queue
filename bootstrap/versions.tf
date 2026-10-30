terraform {
  required_version = "~> 1.9" # any 1.x from 1.9: moving to a future 2.0 must be a deliberate change

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Its own state lives in the storage it creates, next to the other stacks' states. Chicken-and-egg: the very first
  # apply runs on a local state (backend_override.tf), then `terraform init -migrate-state` moves it here.
  # Account and container names are given at init time: terraform init -backend-config=backend.hcl (see the README)
  backend "azurerm" {
    key              = "bootstrap.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  # Subscription: ARM_SUBSCRIPTION_ID environment variable (see README)
  resource_providers_to_register = ["Microsoft.Storage"]
  storage_use_azuread            = true
  features {}
}
