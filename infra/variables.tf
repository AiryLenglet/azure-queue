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
  description = "Service Bus queue the function consumes."
  type        = string
  default     = "orders"

  validation {
    condition     = can(regex("^[a-z0-9]+([.-][a-z0-9]+)*$", var.queue_name)) && length(var.queue_name) <= 260
    error_message = "Lowercase letters, digits, single dots or hyphens, starting and ending with a letter or digit."
  }
}

variable "operator_object_ids" {
  description = "Entra object IDs (users or groups) allowed to send and inspect messages from their machine. Empty: whoever runs terraform apply, fine locally. Set it when a pipeline runs Terraform."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.operator_object_ids : can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", id))])
    error_message = "Object IDs are GUIDs. Yours: az ad signed-in-user show --query id -o tsv"
  }
}

variable "alert_email" {
  description = "Email address the alerts are sent to (README, Monitoring). Set it in terraform.tfvars, which git ignores."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "An email address, such as you@example.com."
  }
}

variable "backlog_alert_threshold" {
  description = "Alert when the queue holds more than this many messages for 15 minutes. Size it as messages processed per second at full scale x seconds an order may wait, above 800 (README, Monitoring)."
  type        = number
  default     = 1000

  validation {
    condition     = var.backlog_alert_threshold >= 0 && floor(var.backlog_alert_threshold) == var.backlog_alert_threshold
    error_message = "A whole number of messages, 0 or more."
  }
}
