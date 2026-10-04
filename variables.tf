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
    # Case flow: queue, case store and the public gateway.
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "apigateway.googleapis.com",
    "servicemanagement.googleapis.com",
    "servicecontrol.googleapis.com",
    "apikeys.googleapis.com",
    # Workload Identity Federation for CI deploys.
    "sts.googleapis.com",
    "iamcredentials.googleapis.com",
    # Analytics: audit log sink into BigQuery.
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

# ---- case flow ---------------------------------------------------------------------------

variable "firestore_collection_prefix" {
  description = "Start of every case store collection name (the agent's FIRESTORE_COLLECTION_PREFIX)."
  type        = string
  default     = "lir_"
}

variable "cases_retention_days" {
  description = "Days an archived case stays in the cases inbox bucket. 0 keeps cases forever."
  type        = number
  default     = 0

  validation {
    condition     = var.cases_retention_days >= 0
    error_message = "cases_retention_days must be 0 (keep forever) or a positive number of days."
  }
}

variable "cases_service_name" {
  description = "Cloud Run service of the case flow (same image as agent_service_name, no IAP)."
  type        = string
  default     = "lir-agent-cases"
}

variable "cases_max_instances" {
  description = "Upper bound of case flow instances. ADK sessions live in memory, so keep 1."
  type        = number
  default     = 1
}

variable "cors_origins" {
  description = "Comma-separated browser origins allowed to call the case flow (lir-web)."
  type        = string
  default     = "http://localhost:5500"
}

variable "telegram_bot_username" {
  description = "Telegram bot username without \"@\", for the start link in the 202 answer. Empty: no link."
  type        = string
  default     = ""

  validation {
    condition     = !startswith(var.telegram_bot_username, "@")
    error_message = "telegram_bot_username goes without the leading \"@\"."
  }
}

# ---- CI deploys --------------------------------------------------------------------------

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may deploy through Workload Identity Federation."
  type        = string
  default     = "Lir-team/factored-hackathon-2026-lir-agent"
}

variable "deploy_branch" {
  description = "Only workflows running on this branch of github_repository may deploy."
  type        = string
  default     = "main"
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

# ---- data pipeline -----------------------------------------------------------------------

variable "pipeline_job_name" {
  description = "Cloud Run job that runs the data pipeline and publishes the data lake."
  type        = string
  default     = "lir-pipeline"
}

variable "pipeline_image" {
  description = "Image of the data pipeline (built with data/cloudbuild.yaml). Empty skips the job."
  type        = string
  default     = ""
}

variable "pipeline_aws_region" {
  description = "Region of the organizers' S3 bucket."
  type        = string
  default     = "us-east-2"
}

variable "pipeline_cpu" {
  description = "vCPUs of the pipeline task (32Gi of memory needs at least 8)."
  type        = string
  default     = "8"
}

variable "pipeline_memory" {
  description = "Memory of the pipeline task. The in-memory filesystem also holds raw/ and the outputs; 8Gi was killed (OOM) staging transactions."
  type        = string
  default     = "32Gi"
}

variable "pipeline_timeout" {
  description = "Maximum duration of one pipeline run."
  type        = string
  default     = "3600s"
}
