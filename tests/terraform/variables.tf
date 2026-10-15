variable "subscription_id" {
  description = "Explicit subscription GUID. Resolve <your-test-subscription> before applying."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "Use the GUID of the intended test subscription."
  }
}

variable "location" {
  type    = string
  default = "australiaeast"
}

variable "name_prefix" {
  description = "Use a different prefix for each independent rig."
  type        = string
  default     = "wstest"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}$", var.name_prefix))
    error_message = "Use 2-11 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "os" {
  description = "One VM per deployment; Windows 11 requires an eligible client license."
  type        = string
  default     = "server2025"

  validation {
    condition     = contains(["server2025", "win11"], var.os)
    error_message = "Choose server2025 or win11."
  }
}

variable "vm_size" {
  description = "D2s_v5 is the low-cost default with nested virtualization; D4s_v5 gives installers more headroom."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "image_version" {
  description = "Resolve and pin a version for repeatable rebuilds; latest is convenient for the first deployment."
  type        = string
  default     = "latest"
}

variable "admin_password" {
  description = "Supply with TF_VAR_admin_password; never commit it. Terraform state still contains this value."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 16 && length(var.admin_password) <= 123
    error_message = "Use a 16-123 character password meeting Azure's complexity requirements."
  }
}

variable "rdp_source_cidr" {
  description = "Your public IPv4 address as a /32; RDP is restricted to this address."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.rdp_source_cidr)) && can(regex("/32$", var.rdp_source_cidr))
    error_message = "Supply a single IPv4 address in CIDR form, for example 203.0.113.10/32."
  }
}
