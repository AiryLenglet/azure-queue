variable "location" {
  description = "Azure region."
  type        = string
  default     = "switzerlandnorth"
}

variable "name" {
  description = "Short name used in every resource name."
  type        = string
  default     = "queuepoc"

  validation {
    condition     = can(regex("^[a-z0-9]{1,14}$", var.name))
    error_message = "Lowercase letters and digits only, 14 characters max (storage account names: st + name + fn + 6-character suffix, 24 max)."
  }
}

variable "queue_name" {
  description = "Main queue. The poison queue is <queue_name>-poison."
  type        = string
  default     = "orders"

  validation {
    # Azure queue names: 3-63 characters, lowercase letters, digits and single hyphens, no hyphen at either end.
    # 56 max here because "-poison" is appended for the poison queue.
    condition     = length(var.queue_name) >= 3 && length(var.queue_name) <= 56 && can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.queue_name))
    error_message = "3 to 56 characters: lowercase letters, digits and single hyphens, starting and ending with a letter or digit."
  }
}

variable "replication_type" {
  description = "LRS is enough for a PoC. Use ZRS (or GZRS) in production."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.replication_type)
    error_message = "One of LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "operator_object_ids" {
  description = "Entra object IDs (users or groups) allowed to send, receive and inspect messages from their machine. Empty: whoever runs terraform apply, fine locally. Set it when a pipeline runs Terraform."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.operator_object_ids : can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", id))])
    error_message = "Object IDs are GUIDs. Yours: az ad signed-in-user show --query id -o tsv"
  }
}
