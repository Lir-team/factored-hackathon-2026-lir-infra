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
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "iap.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "logging.googleapis.com",
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

# ---- agent service -----------------------------------------------------------------------

variable "artifact_repository_id" {
  description = "Artifact Registry Docker repository for the team's images."
  type        = string
  default     = "lir"
}

variable "agent_service_name" {
  description = "Cloud Run service that serves the agent HTTP API."
  type        = string
  default     = "lir-agent"
}

variable "agent_image" {
  description = <<-EOT
    Full image reference of the agent (REGION-docker.pkg.dev/PROJECT/REPO/lir-agent:TAG).
    Empty skips the Cloud Run service, so secrets and the registry can be prepared first.
  EOT
  type        = string
  default     = ""
}

variable "agent_max_instances" {
  description = "Upper bound of agent instances. Sessions live in memory, so keep 1 until they move to Firestore."
  type        = number
  default     = 1
}

variable "llm_model" {
  description = "LiteLLM model string the agent converses with."
  type        = string
  default     = "openai/gpt-4o"
}

variable "agent_store" {
  description = "Data source: auto (DuckDB over staging in the bucket, else the demo fixture), duckdb or fixture."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "duckdb", "fixture"], var.agent_store)
    error_message = "agent_store must be auto, duckdb or fixture."
  }
}

variable "reference_date" {
  description = "Date the agent treats as today (YYYY-MM-DD) to replay a static data snapshot. Empty: current date."
  type        = string
  default     = ""
}

variable "jev_enabled" {
  description = "Use Jev (Cloudflare Workers AI) for typed decisions; needs the Cloudflare secrets."
  type        = bool
  default     = false
}

variable "decisions" {
  description = "Typed decisions: default (Jev when jev_enabled, else the keyword baseline) or llm."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "llm"], var.decisions)
    error_message = "decisions must be default or llm."
  }
}

variable "decision_llm_model" {
  description = "LiteLLM model for decisions = llm (e.g. openrouter/typesafe/jev-router). Empty reuses llm_model."
  type        = string
  default     = ""
}

variable "iap_members" {
  description = "Google accounts allowed through IAP to the agent API, in addition to team_members."
  type        = list(string)
  default     = []
}

# ---- analytics ---------------------------------------------------------------------------

variable "analytics_dataset_id" {
  description = "BigQuery dataset with the audit trail and the evaluation trials."
  type        = string
  default     = "lir_analytics"
}

variable "analytics_location" {
  description = "Location of the analytics dataset."
  type        = string
  default     = "us-east1"
}

variable "analytics_views_enabled" {
  description = "Create the analytics views; enable after the sink has exported its first entry."
  type        = bool
  default     = false
}
