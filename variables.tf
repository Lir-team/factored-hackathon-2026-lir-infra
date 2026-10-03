variable "project_id" {
  description = "GCP project that hosts every Lir resource."
  type        = string
}

variable "project_name" {
  description = "Display name of the project, as shown in the console."
  type        = string
}

variable "organization_id" {
  description = "Numeric id of the team's GCP organization."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.organization_id))
    error_message = "organization_id must be the numeric organization id."
  }
}

variable "folder_display_name" {
  description = "Folder inside the organization that holds the project."
  type        = string
}

variable "billing_account" {
  description = "Billing account linked to the project (XXXXXX-XXXXXX-XXXXXX)."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account))
    error_message = "billing_account must look like XXXXXX-XXXXXX-XXXXXX."
  }
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
  default     = "us-east1"
}

variable "enabled_apis" {
  description = "Google APIs the project needs. Disabling is never done on destroy."
  type        = set(string)
  default = [
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "orgpolicy.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

variable "team_members" {
  description = <<-EOT
    Team members and their project roles, keyed by Google account email.
    Bindings are additive: members and roles not listed here are left untouched.
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for email in keys(var.team_members) : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "Every team_members key must be an email address."
  }

  validation {
    condition     = alltrue([for roles in values(var.team_members) : alltrue([for role in roles : startswith(role, "roles/")])])
    error_message = "Every role must start with \"roles/\"."
  }

  validation {
    condition     = alltrue([for roles in values(var.team_members) : !contains(roles, "roles/owner")])
    error_message = "roles/owner is not granted through Terraform; keep ownership with the project creator."
  }
}
