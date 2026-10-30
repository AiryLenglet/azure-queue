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

  # Remote state in the storage created by ../bootstrap: Entra ID auth, locking (blob lease), versioned.
  # Account and container names are given at init time: terraform init -backend-config=backend.hcl
  backend "azurerm" {
    key              = "queuepoc.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  # Subscription: ARM_SUBSCRIPTION_ID environment variable (see README)

  # azurerm 5.x no longer registers resource providers by default
  resource_providers_to_register = ["Microsoft.Storage", "Microsoft.ManagedIdentity"]

  # Shared keys are disabled on the storage account: any data-plane call must use Entra ID
  storage_use_azuread = true

  features {}
}
